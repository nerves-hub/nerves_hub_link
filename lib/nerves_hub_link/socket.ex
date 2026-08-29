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
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.ArchiveInfo
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.NetworkInterface
  alias NervesHubLink.SupportScriptsManager
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UploadFile

  alias Mint.WebSocket.UpgradeFailureError

  require Logger

  @console_topic "console"
  @device_topic "device"
  @extensions_topic "extensions"

  @firmware_validation_check_interval :timer.seconds(10)

  # How long to wait for NervesHub's answer to a device-initiated update request.
  # Generous: the answer involves the platform resolving a deployment group and,
  # for a request, signing a firmware URL.
  @update_request_timeout :timer.seconds(30)
  @update_request_call_timeout @update_request_timeout + :timer.seconds(5)

  # How long to wait on the connection process when working out which network
  # interface is in use. Short, because nothing depends on the answer.
  @connection_state_timeout 500

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
  How this device receives firmware, as NervesHub last reported it.

  `nil` until NervesHub says — a server too old to know about update modes never
  will, and the device keeps taking updates exactly as it did before.
  """
  @spec update_mode(GenServer.server()) :: NervesHubLink.update_mode() | nil
  def update_mode(server \\ __MODULE__) do
    GenServer.call(server, :update_mode)
  end

  @doc """
  Whether NervesHub allows this device to manage its own updates.
  """
  @spec managed_updates_allowed?(GenServer.server()) :: boolean()
  def managed_updates_allowed?(server \\ __MODULE__) do
    GenServer.call(server, :managed_updates_allowed?)
  end

  @doc """
  Ask NervesHub whether there is firmware waiting for this device.
  """
  @spec check_for_update(GenServer.server()) ::
          {:ok, %{available?: boolean(), firmware_meta: map() | nil}} | {:error, term()}
  def check_for_update(server \\ __MODULE__) do
    GenServer.call(server, :check_for_update, @update_request_call_timeout)
  end

  @doc """
  Ask NervesHub for the firmware itself, and start applying it.
  """
  @spec start_update(GenServer.server()) :: :ok | {:error, term()}
  def start_update(server \\ __MODULE__) do
    GenServer.call(server, :start_update, @update_request_call_timeout)
  end

  @doc """
  Ask NervesHub to change how this device receives firmware.
  """
  @spec set_update_mode(GenServer.server(), :automatic | :device_managed) ::
          :ok | {:error, term()}
  def set_update_mode(server \\ __MODULE__, mode) when mode in [:automatic, :device_managed] do
    GenServer.call(server, {:set_update_mode, mode}, @update_request_call_timeout)
  end

  @spec push_extensions_message(
          GenServer.server(),
          event :: String.t(),
          message :: Slipstream.json_serializable() | {:binary, binary()}
        ) :: {:ok, Slipstream.push_reference()} | {:error, reason :: term()}
  def push_extensions_message(server \\ __MODULE__, event, message) do
    GenServer.call(server, {:push, @extensions_topic, event, message})
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
      |> assign(update_mode: nil)
      |> assign(managed_updates_allowed: false)
      |> assign(pending_update_requests: %{})

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

    {uri, serializer} = serializer_for(config)

    opts = [
      mint_opts: mint_opts(config),
      extensions: mint_extensions(config),
      headers: config.socket[:headers] || [],
      uri: uri,
      rejoin_after_msec: List.flatten([config.rejoin_after]),
      reconnect_after_msec: config.socket[:reconnect_after_msec],
      heartbeat_interval_msec: config.heartbeat_interval_msec,
      serializer: serializer,
      # Lets tests drive this client with `Slipstream.SocketTest` instead of
      # opening a real connection.
      test_mode?: config.socket[:test_mode?] == true
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

    send(self(), :get_network_interface)

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

  def handle_call(:update_mode, _from, socket) do
    {:reply, socket.assigns.update_mode, socket}
  end

  def handle_call(:managed_updates_allowed?, _from, socket) do
    {:reply, socket.assigns.managed_updates_allowed, socket}
  end

  def handle_call(:check_for_update, from, socket) do
    start_update_request(socket, :check_for_update, from, "check_update", %{})
  end

  def handle_call(:start_update, from, socket) do
    # UpdateManager ignores a second update while one is in flight, so asking
    # NervesHub for another firmware URL would only waste a deployment slot.
    if UpdateManager.status() == :updating do
      {:reply, {:error, :updating}, socket}
    else
      start_update_request(socket, :start_update, from, "request_update", %{})
    end
  end

  def handle_call({:set_update_mode, mode}, from, socket) do
    start_update_request(socket, :set_update_mode, from, "set_update_mode", %{mode: mode})
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

        {:started, downloader_network_interface} ->
          %{status: :started, downloader_network_interface: downloader_network_interface}

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

  @impl Slipstream
  ##
  # Device API messages
  #
  def handle_message(@device_topic, "fwup_public_keys", params, socket) do
    config =
      update_public_keys(
        socket.assigns.config,
        :fwup_public_keys,
        params["keys"],
        "firmware"
      )

    {:ok, assign(socket, config: config)}
  end

  def handle_message(@device_topic, "archive_public_keys", params, socket) do
    config =
      update_public_keys(
        socket.assigns.config,
        :archive_public_keys,
        params["keys"],
        "archive"
      )

    {:ok, assign(socket, config: config)}
  end

  def handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warning("[NervesHubLink] Reboot Request from NervesHub")
    _ = push(socket, @device_topic, "rebooting", %{})
    # TODO: Maybe allow delayed reboot
    Client.initiate_reboot()
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
        # The same message answers a `request_update` and carries a deployment's
        # own push; resolving is a no-op when nothing asked.
        {:ok, resolve_update_request(socket, :start_update, :ok)}

      error ->
        Logger.error(
          "[NervesHubLink] Error parsing update data: #{inspect(update)} error: #{inspect(error)}"
        )

        {:ok, socket}
    end
  end

  def handle_message(@device_topic, "update_mode", params, socket) do
    socket =
      socket
      |> assign(update_mode: parse_update_mode(params["mode"]))
      |> assign(managed_updates_allowed: params["managed_updates_allowed"] == true)

    result =
      case params["error"] do
        nil -> :ok
        error -> {:error, update_request_error(error)}
      end

    {:ok, resolve_update_request(socket, :set_update_mode, result)}
  end

  def handle_message(@device_topic, "update_available", params, socket) do
    result =
      {:ok,
       %{
         available?: params["available"] == true,
         firmware_meta: params["firmware_meta"]
       }}

    {:ok, resolve_update_request(socket, :check_for_update, result)}
  end

  def handle_message(@device_topic, "update_rejected", params, socket) do
    result =
      case {params["reason"], params["delay_for"]} do
        {"busy", delay} when is_integer(delay) -> {:error, {:busy, delay}}
        {reason, _} -> {:error, update_request_error(reason)}
      end

    {:ok, resolve_update_request(socket, :start_update, result)}
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

  def handle_info({:update_request_timeout, kind}, socket) do
    {:noreply, resolve_update_request(socket, kind, {:error, :timeout})}
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

  def handle_info(:get_network_interface, socket) do
    case network_interface(socket) do
      interface when is_binary(interface) ->
        _ = push(socket, @device_topic, "report_network_interface", %{interface: interface})
        {:noreply, assign(socket, network_interface: interface)}

      result ->
        Logger.warning(
          "[NervesHubLink] Could not determine network interface: #{inspect(result)}"
        )

        Process.send_after(self(), :get_network_interface, 60_000)
        {:noreply, socket}
    end
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
          # in a connection attempt again.
          #
          # When the failed upgrade response carried a `Date` header, sign
          # with that time instead of the device clock — recovers devices
          # whose RTC/NTP isn't trustworthy yet.
          hint = SharedSecret.server_time_hint(reason)
          headers = SharedSecret.headers(socket.assigns.config, hint)
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

  # The connection process is inspected with `:sys.get_state/2` rather than
  # asked, so everything here has to be treated as best-effort: a connection
  # process that is busy or gone, or that holds a state shape this code doesn't
  # know, must not take this socket down with it. Reporting the interface
  # is informational, losing the connection over it is not a trade worth making.
  defp network_interface(socket) do
    with pid when is_pid(pid) <- Slipstream.Socket.channel_pid(socket),
         %{conn: conn} <- :sys.get_state(pid, @connection_state_timeout) do
      NetworkInterface.from_socket(Mint.HTTP.get_socket(conn))
    end
  catch
    kind, reason -> {kind, reason}
  end

  # Falling back to JSON rather than raising: a serializer the device can't use
  # is a configuration mistake, and refusing to connect over it would leave the
  # device unreachable, including for the update that would fix the mistake.
  defp serializer_for(%{serializer: :msgpack} = config) do
    if Code.ensure_loaded?(NervesHubLink.MsgPackSerializer) do
      uri = %{config.socket[:url] | query: URI.encode_query(%{vsn: "3.0.0"})}
      {uri, NervesHubLink.MsgPackSerializer}
    else
      Logger.error(
        "[NervesHubLink] the :msgpack serializer needs the :msgpax dependency, using JSON instead"
      )

      json_serializer(config)
    end
  end

  defp serializer_for(%{serializer: :json} = config), do: json_serializer(config)

  defp serializer_for(config) do
    Logger.error(
      "[NervesHubLink] unknown serializer #{inspect(config.serializer)}, using JSON instead"
    )

    json_serializer(config)
  end

  defp json_serializer(config) do
    {config.socket[:url], Slipstream.Serializer.PhoenixSocketV2Serializer}
  end

  # A device-initiated request is answered by a separate message rather than a
  # reply to the push, so the caller is parked here until that message arrives —
  # or until the timeout does, so a lost answer cannot leak a stuck caller.
  defp start_update_request(socket, kind, from, event, payload) do
    cond do
      not joined?(socket, @device_topic) ->
        {:reply, {:error, :disconnected}, socket}

      Map.has_key?(socket.assigns.pending_update_requests, kind) ->
        {:reply, {:error, :already_in_progress}, socket}

      true ->
        case push(socket, @device_topic, event, payload) do
          {:ok, _ref} ->
            timer =
              Process.send_after(self(), {:update_request_timeout, kind}, @update_request_timeout)

            pending = Map.put(socket.assigns.pending_update_requests, kind, {from, timer})

            {:noreply, assign(socket, pending_update_requests: pending)}

          {:error, reason} ->
            {:reply, {:error, reason}, socket}
        end
    end
  end

  defp resolve_update_request(socket, kind, result) do
    case Map.pop(socket.assigns.pending_update_requests, kind) do
      {nil, _pending} ->
        socket

      {{from, timer}, pending} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, result)
        assign(socket, pending_update_requests: pending)
    end
  end

  defp parse_update_mode("automatic"), do: :automatic
  defp parse_update_mode("device_managed"), do: :device_managed
  defp parse_update_mode("off"), do: :off

  defp parse_update_mode(mode) do
    Logger.warning("[NervesHubLink] unknown update mode from NervesHub : #{inspect(mode)}")
    nil
  end

  # Mapped rather than converted, so a reason NervesHub invents later cannot grow
  # this device's atom table.
  defp update_request_error("not_permitted"), do: :not_permitted
  defp update_request_error("unknown_mode"), do: :unknown_mode
  defp update_request_error("no_update"), do: :no_update
  defp update_request_error("no_deployment_group"), do: :no_deployment_group
  defp update_request_error(_other), do: :error

  defp alarm_if_firmware_auto_reverted() do
    if Client.firmware_auto_revert_detected?() do
      Alarms.set_alarm({NervesHubLink.FirmwareReverted, []})
    else
      :ok
    end
  end

  @doc false
  @spec mint_opts(Configurator.Config.t()) :: keyword()
  def mint_opts(config) do
    base =
      if config.socket[:url].scheme == "wss" do
        [protocols: [:http1], transport_opts: config.ssl]
      else
        [protocols: [:http1]]
      end

    merge_http_opts(base, config.socket[:http_opts] || [])
  end

  # NervesHub distributes signing keys over the socket, but it also supplies the
  # firmware those keys verify. Letting it replace a locally configured key list
  # with an empty one would let the server turn off signature verification, so
  # an empty list never clears keys we already hold.
  @spec update_public_keys(Configurator.Config.t(), atom(), any(), String.t()) ::
          Configurator.Config.t()
  defp update_public_keys(config, field, received_keys, label) do
    received_keys =
      if is_list(received_keys), do: Enum.filter(received_keys, &is_binary/1), else: []

    existing_keys = Map.fetch!(config, field)

    cond do
      received_keys != [] ->
        Logger.info(
          "[NervesHubLink] Public keys for #{label} verification updated - #{length(received_keys)} key(s) received"
        )

        Map.put(config, field, received_keys)

      FwupConfig.signing_keys_available?(existing_keys) ->
        Logger.error(
          "[NervesHubLink] NervesHub sent no public keys for #{label} verification : keeping the #{length(existing_keys)} locally configured key(s)"
        )

        config

      true ->
        Logger.error(
          "[NervesHubLink] No public keys for #{label} verification are available : #{label} updates will be refused"
        )

        config
    end
  end

  # Shallow-merge user-supplied opts on top of the base, but for :transport_opts
  # specifically merge the nested keyword list so callers who only want to add
  # e.g. a :timeout don't accidentally clobber our SSL config.
  defp merge_http_opts(base, user_opts) do
    Keyword.merge(base, user_opts, fn
      :transport_opts, base_v, user_v -> Keyword.merge(base_v, user_v)
      _key, _base_v, user_v -> user_v
    end)
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

  # The console only needs to know which protocol versions it is talking to.
  # The rest of the join params describe the device and its firmware, and the
  # device channel has already sent them.
  @console_join_params ["console_version", "device_api_version"]

  defp maybe_join_console(socket) do
    if socket.assigns.remote_iex do
      join(socket, @console_topic, Map.take(socket.assigns.params, @console_join_params))
    else
      socket
    end
  end

  defp set_iex_timer(socket) do
    timeout = socket.assigns.config.remote_iex_timeout * 1000

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
end
