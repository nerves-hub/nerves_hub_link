# SPDX-FileCopyrightText: 2021 Connor Rigby
# SPDX-FileCopyrightText: 2021 Frank Hunleth
# SPDX-FileCopyrightText: 2021 Jon Carstens
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Socket do
  @moduledoc false

  use Slipstream

  alias NervesHubLink.Alarms
  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Configurator.SharedSecret
  alias NervesHubLink.Extensions
  alias NervesHubLink.Message.ArchiveInfo
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.SupportScriptsManager
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UploadFile

  alias Mint.WebSocket.UpgradeFailureError

  require Logger

  @console_topic "console"
  @device_topic "device"
  @extensions_topic "extensions"

  @firmware_validation_check_interval :timer.seconds(10)

  @max_redirects 2

  @spec start_link(Configurator.Config.t(), GenServer.options()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, opts)
  end

  @spec reconnect!(GenServer.server()) :: :ok
  def reconnect!(server \\ __MODULE__) do
    GenServer.cast(server, :reconnect)
  end

  @spec send_update_status(GenServer.server(), NervesHubLink.update_status()) :: :ok
  def send_update_status(server \\ __MODULE__, status) do
    GenServer.cast(server, {:send_update_status, status})
  end

  @spec check_connection(GenServer.server(), atom()) :: boolean()
  def check_connection(server \\ __MODULE__, type) do
    GenServer.call(server, {:check_connection, type})
  end

  @spec send_file(GenServer.server(), Path.t()) :: :ok | {:error, :too_large | File.posix()}
  def send_file(server \\ __MODULE__, file_path) do
    GenServer.call(server, {:send_file, file_path})
  end

  @doc false
  @spec start_uploading(GenServer.server(), String.t()) :: :ok | :error
  def start_uploading(server \\ __MODULE__, filename) do
    GenServer.call(server, {:start_uploading, filename})
  end

  @doc false
  @spec upload_data(GenServer.server(), String.t(), any(), any()) :: :ok | :error
  def upload_data(server \\ __MODULE__, filename, index, chunk) do
    GenServer.call(server, {:upload_data, filename, index, chunk})
  end

  @doc false
  @spec finish_uploading(GenServer.server(), String.t()) :: :ok | :error
  def finish_uploading(server \\ __MODULE__, filename) do
    GenServer.call(server, {:finish_uploading, filename})
  end

  @doc """
  Cancel an ongoing upload

  Escape hatch for uploading files via the console, kill the upload
  process to stop uploading.
  """
  @spec cancel_upload(GenServer.server()) :: :ok | :error
  def cancel_upload(server \\ __MODULE__) do
    GenServer.call(server, :cancel_upload)
  end

  @doc """
  Return whether an IEx or other console session is active
  """
  @spec console_active?(GenServer.server()) :: boolean()
  def console_active?(server \\ __MODULE__) do
    GenServer.call(server, :console_active?)
  end

  @doc """
  Let NervesHub know the network interface has changed
  """
  @spec send_network_interface_mismatch(GenServer.server(), binary(), binary()) :: :ok
  def send_network_interface_mismatch(server \\ __MODULE__, expected, current) do
    GenServer.cast(server, {:send_network_interface_mismatch, expected, current})
  end

  @spec push_extensions_message(
          GenServer.server(),
          event :: String.t(),
          message :: Slipstream.json_serializable() | {:binary, binary()}
        ) :: {:ok, Slipstream.push_reference()} | {:error, reason :: term()}
  def push_extensions_message(server \\ __MODULE__, event, message) do
    GenServer.call(server, {:push, @extensions_topic, event, message})
  end

  @spec get_network_interface(GenServer.server()) :: binary() | nil
  def get_network_interface(server \\ __MODULE__) do
    GenServer.call(server, :get_network_interface)
  end

  @impl Slipstream
  def init(config) do
    Alarms.set_alarm({NervesHubLink.Disconnected, []})

    alarm_if_firmware_auto_reverted()

    socket =
      new_socket()
      |> assign(config: config)
      |> assign(params: config.params)
      |> assign(remote_iex: config.remote_iex)
      |> assign(iex_pid: nil)
      |> assign(iex_timer: nil)
      |> assign(uploader_pid: nil)
      |> assign(data_path: config.data_path)
      |> assign(started_at: System.monotonic_time(:millisecond))
      |> assign(connected_at: nil)
      |> assign(joined_at: nil)
      |> assign(firmware_validation_timer_pid: nil)
      |> assign(redirect_count: 0)

    if config.connect_wait_for_network do
      schedule_network_availability_check()
      {:ok, socket}
    else
      {:ok, socket, {:continue, :connect}}
    end
  end

  @impl Slipstream
  def handle_continue(:connect, %{assigns: %{config: config}} = socket) do
    Logger.info("[NervesHubLink] connecting to #{config.socket[:url].host}")

    opts = [
      mint_opts: mint_opts(config),
      extensions: mint_extensions(config),
      headers: config.socket[:headers] || [],
      uri: config.socket[:url],
      rejoin_after_msec: List.flatten([config.rejoin_after]),
      reconnect_after_msec: config.socket[:reconnect_after_msec],
      heartbeat_interval_msec: config.heartbeat_interval_msec
    ]

    socket = connect!(socket, opts)

    Process.flag(:trap_exit, true)

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_connect(%{assigns: %{config: config}} = socket) do
    Logger.info("[NervesHubLink] connection to #{config.socket[:url].host} succeeded")

    currently_downloading_uuid = UpdateManager.currently_downloading_uuid()

    device_join_params =
      socket.assigns.params
      |> Map.put("currently_downloading_uuid", currently_downloading_uuid)
      |> Map.put("meta", %{
        "firmware_auto_revert_detected" => Client.firmware_auto_revert_detected?(),
        "firmware_validated" => Client.firmware_validated?()
      })

    socket =
      socket
      |> assign(params: device_join_params)
      |> join(@device_topic, device_join_params)
      |> maybe_join_console()
      |> assign(connected_at: System.monotonic_time(:millisecond))
      |> assign(redirect_count: 0)

    Alarms.clear_alarm(NervesHubLink.Disconnected)

    Client.connected()

    socket = schedule_firmware_validation_status_check(socket)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(@device_topic, _reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Device channel")

    _ = maybe_report_current_network_interface(socket)

    {:ok, assign(socket, joined_at: System.monotonic_time(:millisecond))}
  end

  def handle_join(@console_topic, _reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Console channel")
    {:ok, socket}
  end

  def handle_join(@extensions_topic, extensions, socket) do
    Extensions.attach(extensions)
    Logger.debug("[#{inspect(__MODULE__)}] Joined Extensions channel")
    {:ok, socket}
  end

  def handle_call({:check_connection, :device}, _from, socket) do
    {:reply, joined?(socket, @device_topic), socket}
  end

  @impl Slipstream
  def handle_call({:check_connection, :console}, _from, socket) do
    {:reply, joined?(socket, @console_topic), socket}
  end

  def handle_call({:check_connection, :extensions}, _from, socket) do
    {:reply, joined?(socket, @extensions_topic), socket}
  end

  def handle_call({:check_connection, :socket}, _from, socket) do
    {:reply, connected?(socket), socket}
  end

  def handle_call(:console_active?, _from, socket) do
    {:reply, socket.assigns.iex_pid != nil, socket}
  end

  def handle_call({:push, topic, event, payload}, _from, socket) do
    {:reply, push(socket, topic, event, payload), socket}
  end

  def handle_call({:send_file, file_path}, _from, socket) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size < 10_485_760 ->
        {:ok, uploader_pid} = UploadFile.start_link(file_path, self())
        {:reply, :ok, assign(socket, :uploader_pid, uploader_pid)}

      {:ok, _} ->
        {:reply, {:error, :too_large}, socket}

      {:error, posix} ->
        {:reply, {:error, posix}, socket}
    end
  end

  def handle_call({:start_uploading, filename}, _from, socket) do
    if socket.assigns.uploader_pid do
      _ = push(socket, @console_topic, "file-data/start", %{filename: filename})
      {:reply, :ok, socket}
    else
      {:reply, :error, socket}
    end
  end

  def handle_call({:upload_data, filename, index, chunk}, _from, socket) do
    if socket.assigns.uploader_pid do
      _ =
        push(socket, @console_topic, "file-data", %{
          filename: filename,
          chunk: index,
          data: Base.encode64(chunk)
        })

      {:reply, :ok, socket}
    else
      {:reply, :error, socket}
    end
  end

  def handle_call({:finish_uploading, filename}, _from, socket) do
    if socket.assigns.uploader_pid do
      _ = push(socket, @console_topic, "file-data/stop", %{filename: filename})
      {:reply, :ok, assign(socket, :uploader_pid, nil)}
    else
      {:reply, :error, socket}
    end
  end

  def handle_call(:cancel_upload, _from, socket) do
    if socket.assigns.uploader_pid do
      true = Process.exit(socket.assigns.uploader_pid, :kill)
      {:reply, :ok, socket}
    else
      {:reply, :error, socket}
    end
  end

  def handle_call(:get_network_interface, _from, socket) do
    interface = current_network_interface(socket)

    {:reply, interface, socket}
  end

  @impl Slipstream
  def handle_cast(:reconnect, socket) do
    # See handle_disconnect/2 for the reconnect call once the connection is closed.
    {:noreply, disconnect(socket)}
  end

  def handle_cast({:send_update_status, {stage, progress}}, socket)
      when stage in [:downloading, :updating] do
    _ = push(socket, @device_topic, "fwup_progress", %{stage: stage, value: progress})
    {:noreply, socket}
  end

  def handle_cast({:send_update_status, status}, socket) do
    payload =
      case status do
        :received ->
          %{status: :received}

        :completed ->
          # Make sure older versions of Hub get the final 100% message
          _ = push(socket, @device_topic, "fwup_progress", %{stage: :updating, value: 100})
          %{status: :completed}

        {:ignored, reason} ->
          %{status: :ignored, reason: reason}

        {:reschedule, delay_for} ->
          %{status: :rescheduled, delay_for: delay_for}

        {:reschedule, delay_for, reason} ->
          %{status: :rescheduled, delay_for: delay_for, reason: reason}

        {:failed, reason} ->
          %{status: :failed, reason: reason}
      end

    _ = push(socket, @device_topic, "status_update", payload)

    {:noreply, socket}
  end

  def handle_cast({:send_network_interface_mismatch, expected, current}, socket) do
    _ =
      push(socket, @device_topic, "network_interface_mismatch", %{
        expected: expected,
        current: current
      })

    {:noreply, socket}
  end

  @impl Slipstream
  ##
  # Device API messages
  #
  def handle_message(@device_topic, "fwup_public_keys", params, socket) do
    count = Enum.count(params["keys"])

    config = %{socket.assigns.config | fwup_public_keys: params["keys"]}

    if count == 0 do
      Logger.warning(
        "[NervesHubLink] No public keys for firmware verification received : firmware updates cannot be verified and installed"
      )
    else
      Logger.info(
        "[NervesHubLink] Public keys for firmware verification updated - #{count} key(s) received"
      )
    end

    {:ok, assign(socket, config: config)}
  end

  def handle_message(@device_topic, "archive_public_keys", params, socket) do
    count = Enum.count(params["keys"])

    config = %{socket.assigns.config | archive_public_keys: params["keys"]}

    if count == 0 do
      Logger.warning(
        "[NervesHubLink] No public keys for archive verification received : archive updates cannot be verified and installed"
      )
    else
      Logger.info(
        "[NervesHubLink] Public keys for archive verification updated - #{count} key(s) received"
      )
    end

    {:ok, assign(socket, config: config)}
  end

  def handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warning("[NervesHubLink] Reboot Request from NervesHub")
    _ = push(socket, @device_topic, "rebooting", %{})
    # TODO: Maybe allow delayed reboot
    Nerves.Runtime.reboot()
    {:ok, socket}
  end

  def handle_message(@device_topic, "identify", _params, socket) do
    Client.identify()
    {:ok, socket}
  end

  def handle_message(@device_topic, "scripts/run", params, socket) do
    # See related handle_info for pushing back the script result
    :ok = SupportScriptsManager.start_task(params["ref"], params["text"], params["timeout"])
    {:ok, socket}
  end

  def handle_message(@device_topic, "archive", params, socket) do
    {:ok, info} = ArchiveInfo.parse(params)
    _ = ArchiveManager.apply_archive(info, socket.assigns.config.archive_public_keys)
    {:ok, socket}
  end

  def handle_message(@device_topic, "update", update, socket) do
    case UpdateInfo.parse(update) do
      {:ok, %UpdateInfo{} = info} ->
        _ = UpdateManager.apply_update(info, socket.assigns.config.fwup_public_keys)
        {:ok, socket}

      error ->
        Logger.error(
          "[NervesHubLink] Error parsing update data: #{inspect(update)} error: #{inspect(error)}"
        )

        {:ok, socket}
    end
  end

  def handle_message(@device_topic, "extensions:get", _payload, socket) do
    available_extensions =
      for {name, %{version: ver}} <- Extensions.list(),
          into: %{},
          do: {name, to_string(ver)}

    {:ok, join(socket, "extensions", available_extensions)}
  end

  ##
  # Console API messages
  #
  def handle_message(@console_topic, "restart", _payload, socket) do
    Logger.warning("[#{inspect(__MODULE__)}] Restarting IEx process from web request")

    _ = push(socket, @console_topic, "up", %{data: "\r*** Restarting IEx ***\r"})

    socket =
      socket
      |> stop_iex()
      |> start_iex()

    {:ok, set_iex_timer(socket)}
  end

  def handle_message(@console_topic, message, payload, %{assigns: %{iex_pid: nil}} = socket) do
    handle_message(@console_topic, message, payload, start_iex(socket))
  end

  def handle_message(@console_topic, "dn", %{"data" => data}, socket) do
    _ = ExTTY.send_text(socket.assigns.iex_pid, data)
    {:ok, set_iex_timer(socket)}
  end

  def handle_message(
        @console_topic,
        "window_size",
        %{"height" => height, "width" => width},
        socket
      ) do
    _ = ExTTY.window_change(socket.assigns.iex_pid, width, height)
    {:ok, set_iex_timer(socket)}
  end

  def handle_message(@console_topic, "file-data/start", params, socket) do
    :ok = File.mkdir_p!(socket.assigns.data_path)
    path = Path.join(socket.assigns.data_path, params["filename"])
    _ = File.rm_rf!(path)
    :ok = File.touch!(path)
    {:ok, socket}
  end

  def handle_message(@console_topic, "file-data", params, socket) do
    path = Path.join(socket.assigns.data_path, params["filename"])

    _res =
      File.open!(path, [:append], fn fd ->
        chunk = Base.decode64!(params["data"])
        IO.binwrite(fd, chunk)
      end)

    {:ok, socket}
  end

  def handle_message(@console_topic, "file-data/stop", _params, socket) do
    {:ok, socket}
  end

  def handle_message(@extensions_topic, event, payload, socket) do
    Extensions.handle_event(event, payload)
    {:ok, socket}
  end

  ##
  # Unknown message
  #
  def handle_message(topic, event, _params, socket) do
    Logger.warning("Unknown message (\"#{topic}:#{event}\") received")

    {:ok, socket}
  end

  @impl Slipstream
  def handle_info(:connect_check_network_availability, socket) do
    uri = URI.parse(socket.assigns.config.socket[:url])

    case :gen_tcp.connect(to_charlist(uri.host), uri.port, [active: false, packet: 0], 2_000) do
      {:ok, tcp_socket} ->
        :gen_tcp.close(tcp_socket)
        {:noreply, socket, {:continue, :connect}}

      {:error, _reason} ->
        Logger.info("[NervesHubLink] waiting for network to become available")
        schedule_network_availability_check(3_000)
        {:noreply, socket}
    end
  end

  def handle_info(:firmware_validation_status_check, socket) do
    if Client.firmware_validated?() do
      Logger.info("[NervesHubLink] Firmware is validated, notifying NervesHub")
      _ = push(socket, @device_topic, "firmware_validated", %{})
      {:noreply, assign(socket, :firmware_validation_timer_pid, nil)}
    else
      Logger.debug(
        "[NervesHubLink] Firmware is not marked as validated, checking again in #{@firmware_validation_check_interval / 1000} seconds"
      )

      {:noreply, schedule_firmware_validation_status_check(socket)}
    end
  end

  def handle_info({"scripts/result", identifier, result}, socket) do
    payload =
      case result do
        {:ok, result, output} ->
          %{
            ref: identifier,
            result: "completed",
            output: output,
            return: inspect(result, pretty: true)
          }

        {:error, :timeout} ->
          %{
            ref: identifier,
            result: "error",
            reason: "timeout",
            output: "Error running script: timeout exceeded",
            return: ""
          }

        {:error, reason} ->
          %{
            ref: identifier,
            result: "error",
            reason: inspect(reason, pretty: true),
            output: "Error running script: #{inspect(reason, pretty: true)}",
            return: ""
          }
      end

    _ = push(socket, @device_topic, "scripts/run", payload)

    {:noreply, socket}
  end

  def handle_info({:tty_data, data}, socket) do
    _ = push(socket, @console_topic, "up", %{data: data})
    {:noreply, set_iex_timer(socket)}
  end

  def handle_info({:EXIT, iex_pid, reason}, %{assigns: %{iex_pid: iex_pid}} = socket) do
    msg = "Remote IEx stopped: #{inspect(reason)}"
    _ = push(socket, @console_topic, "up", %{data: "\r******* #{msg} *******\r"})
    Logger.warning("[NervesHubLink] #{msg}")

    socket =
      socket
      |> start_iex()
      |> set_iex_timer()

    {:noreply, socket}
  end

  def handle_info(
        {:EXIT, uploader_pid, :killed},
        %{assigns: %{uploader_pid: uploader_pid}} = socket
      ) do
    Logger.info("[#{inspect(__MODULE__)}] Upload cancelled")

    {:noreply, assign(socket, :uploader_pid, nil)}
  end

  def handle_info({:EXIT, port, reason}, socket) when is_port(port) do
    Logger.debug(
      "[NervesHubLink] Ignoring :Exit message from Slipstream connection Port (#{inspect(port)} : #{reason})"
    )

    {:noreply, socket}
  end

  def handle_info(:iex_timeout, socket) do
    msg = """
    \r
    ****************************************\r
    *   Session timeout due to inactivity  *\r
    *                                      *\r
    *   Press any key to continue...       *\r
    ****************************************\r
    """

    _ = push(socket, @console_topic, "up", %{data: msg})

    {:noreply, stop_iex(socket)}
  end

  def handle_info(msg, socket) do
    Logger.warning("[#{inspect(__MODULE__)}] Unhandled handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_reply(ref, {:error, "detach"}, socket) do
    Extensions.detach(ref)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) when reason != :left do
    if topic == @device_topic do
      _ = Client.handle_error(reason)
    end

    rejoin(socket, topic)
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    _ = Client.handle_error(reason)
    :alarm_handler.set_alarm({NervesHubLink.Disconnected, [reason: reason]})
    channel_config = %{socket.channel_config | reconnect_after_msec: Client.reconnect_backoff()}

    channel_config =
      case Configurator.fetch_configurator() do
        SharedSecret ->
          # TODO: I don't know when reconnect/1 actually gets validated. It could be that
          # the signature we create here will be too old before the headers are used
          # in a connection attempt again
          headers = SharedSecret.headers(socket.assigns.config)
          %{channel_config | headers: headers}

        _ ->
          channel_config
      end

    %{socket | channel_config: channel_config}
    |> handle_redirect(reason)
  end

  defp handle_redirect(
         %{assigns: %{redirect_count: redirect_count}} = socket,
         {:error,
          {:upgrade_failure,
           %{reason: %UpgradeFailureError{status_code: status, headers: headers}}}} = error
       )
       when status >= 300 and status < 400 do
    if redirect_count < @max_redirects do
      {_, location} = Enum.find(headers, fn {k, _v} -> k == "location" end)

      uri = URI.merge(socket.channel_config.uri, URI.parse(location))

      uri =
        case uri.scheme do
          "http" -> %{uri | scheme: "ws"}
          "https" -> %{uri | scheme: "wss"}
          _ -> uri
        end

      channel_config = %{socket.channel_config | uri: uri}

      Logger.info("[NervesHubLink] redirect received : #{URI.to_string(uri)}")

      %{socket | channel_config: channel_config}
      |> update(:redirect_count, &(&1 + 1))
      |> reconnect()
    else
      Logger.error("[NervesHubLink] maximum redirect count reached : #{inspect(error)}")
      {:ok, socket}
    end
  end

  defp handle_redirect(socket, _reason) do
    reconnect(socket)
  end

  @impl Slipstream
  def terminate(_reason, socket) do
    disconnect(socket)
  end

  defp alarm_if_firmware_auto_reverted() do
    if Client.firmware_auto_revert_detected?() do
      Alarms.set_alarm({NervesHubLink.FirmwareReverted, []})
    else
      :ok
    end
  end

  defp mint_opts(config) do
    if config.socket[:url].scheme == "wss" do
      [protocols: [:http1], transport_opts: config.ssl]
    else
      [protocols: [:http1]]
    end
  end

  defp mint_extensions(config) do
    if config.compress do
      [Mint.WebSocket.PerMessageDeflate]
    else
      []
    end
  end

  defp schedule_network_availability_check(delay \\ 100) do
    Process.send_after(self(), :connect_check_network_availability, delay)
  end

  defp schedule_firmware_validation_status_check(socket) do
    if socket.assigns.params["meta"]["firmware_validated"] == true do
      Logger.debug("[NervesHubLink] Firmware validated and information sent during connection")
      socket
    else
      maybe_cancel_timer(socket.assigns[:firmware_validation_timer_pid])

      pid =
        Process.send_after(
          self(),
          :firmware_validation_status_check,
          @firmware_validation_check_interval
        )

      assign(socket, :firmware_validation_timer_pid, pid)
    end
  end

  defp maybe_join_console(socket) do
    if socket.assigns.remote_iex do
      join(socket, @console_topic, socket.assigns.params)
    else
      socket
    end
  end

  defp set_iex_timer(socket) do
    timeout = socket.assigns.config.remote_iex_timeout

    maybe_cancel_timer(socket.assigns[:iex_timer])

    assign(socket, iex_timer: Process.send_after(self(), :iex_timeout, timeout))
  end

  defp start_iex(socket) do
    shell_opts = [[dot_iex_path: dot_iex_path()]]
    {:ok, iex_pid} = ExTTY.start_link(handler: self(), type: :elixir, shell_opts: shell_opts)
    assign(socket, iex_pid: iex_pid)
  end

  defp dot_iex_path() do
    [".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
  end

  defp stop_iex(%{assigns: %{iex_pid: nil}} = socket), do: socket

  defp stop_iex(%{assigns: %{iex_pid: iex}} = socket) do
    _ = Process.unlink(iex)
    GenServer.stop(iex, :normal, 10_000)
    assign(socket, iex_pid: nil)
  end

  defp maybe_cancel_timer(nil), do: :ok

  defp maybe_cancel_timer(pid) do
    _ = Process.cancel_timer(pid)
    :ok
  end

  @spec current_network_interface(Slipstream.Socket.t()) :: binary() | nil
  def current_network_interface(socket) do
    channel_state = :sys.get_state(socket.channel_pid)

    {:ok, {ip, _}} = :ssl.sockname(channel_state.conn.socket)
    {:ok, interfaces} = :inet.getifaddrs()

    {interface, _attrs} = Enum.find(interfaces, fn {_name, attrs} -> attrs[:addr] == ip end)

    # charlist -> string
    List.to_string(interface)
  rescue
    err ->
      Logger.warning(
        "[NervesHubLink] Error: could not determine network interface: #{inspect(err)}"
      )

      nil
  end

  def maybe_report_current_network_interface(socket) do
    interface = current_network_interface(socket)

    if interface do
      Logger.info(
        "[NervesHubLink] Reporting network interface #{inspect(interface)} to NervesHub"
      )

      _ =
        push(socket, @device_topic, "network_interface_mismatch", %{network_interface: interface})

      UpdateManager.set_initial_network_interface(interface)

      :ok
    else
      :ok
    end
  end
end
