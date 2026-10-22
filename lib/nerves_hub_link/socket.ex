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

  use GenServer

  alias NervesHubLink.Alarms
  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Configurator.SharedSecret
  alias NervesHubLink.Connection
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

  defmodule State do
    @moduledoc false

    defstruct [
      :config,
      :connection,
      :data_path,
      :firmware_validation_timer,
      :heartbeat_timer,
      :iex_pid,
      :iex_timer,
      :params,
      :remote_iex,
      :signing_time_hint,
      :update_mode,
      :uploader_pid,
      managed_updates_allowed: false,
      pending_update_requests: %{},
      redirect_count: 0
    ]

    @type t :: %__MODULE__{
            config: NervesHubLink.Configurator.Config.t(),
            connection: NervesHubLink.Connection.t(),
            data_path: Path.t(),
            firmware_validation_timer: reference() | nil,
            heartbeat_timer: reference() | nil,
            iex_pid: pid() | nil,
            iex_timer: reference() | nil,
            params: map(),
            remote_iex: boolean(),
            signing_time_hint: DateTime.t() | nil,
            update_mode: NervesHubLink.update_mode() | nil,
            uploader_pid: pid() | nil,
            managed_updates_allowed: boolean(),
            pending_update_requests: map(),
            redirect_count: non_neg_integer()
          }
  end

  @console_topic "console"
  @device_topic "device"
  @extensions_topic "extensions"

  @firmware_validation_check_interval :timer.seconds(10)

  # How long to wait for NervesHub's answer to a device-initiated update request.
  # Generous: the answer involves the platform resolving a deployment group and,
  # for a request, signing a firmware URL.
  @update_request_timeout :timer.seconds(30)
  @update_request_call_timeout @update_request_timeout + :timer.seconds(5)

  @max_redirects 2

  # The protocol version is part of the URL rather than of the serializer
  # module, because the server picks its serializer from the `vsn` query
  # parameter. The two are decided together so they cannot disagree.
  @json_vsn "2.0.0"
  @msgpack_vsn "3.0.0"

  # A payload to push over the socket: either a term the configured serializer
  # can encode, or an already encoded binary frame.
  @type push_payload :: term() | {:binary, binary()}

  # The `ref` a push was sent with. The server's reply to that push carries the
  # same ref, which is how the two are matched up.
  @type push_ref :: String.t()

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
          message :: push_payload()
        ) :: {:ok, push_ref()} | {:error, reason :: term()}
  def push_extensions_message(server \\ __MODULE__, event, message) do
    GenServer.call(server, {:push, @extensions_topic, event, message})
  end

  @impl GenServer
  def init(config) do
    # The console and the file uploader are linked to this process, and their
    # exits are handled below rather than taken as a reason to go down too.
    Process.flag(:trap_exit, true)

    Alarms.set_alarm({NervesHubLink.Disconnected, []})

    alarm_if_firmware_auto_reverted()

    {uri, serializer} = serializer_for(config)

    connection =
      Connection.new(
        uri: uri,
        serializer: serializer,
        mint_opts: mint_opts(config),
        extensions: mint_extensions(config),
        upgrade_timeout_msec: config.upgrade_timeout_msec,
        reconnect_after_msec: backoff_list(config.socket[:reconnect_after_msec], 1_000),
        rejoin_after_msec: backoff_list(config.rejoin_after, 5_000)
      )

    socket = %State{
      config: config,
      connection: connection,
      data_path: config.data_path,
      params: config.params,
      remote_iex: config.remote_iex
    }

    if config.connect_wait_for_network do
      schedule_network_availability_check()
      {:ok, socket}
    else
      {:ok, socket, {:continue, :connect}}
    end
  end

  @impl GenServer
  def handle_continue(:connect, socket) do
    {:noreply, connect(socket)}
  end

  # The headers are made here, per attempt, rather than once at startup. A
  # shared-secret signature is only good for a window around the time it was
  # made, so signing when the last attempt failed - which may have been a long
  # backoff ago - produces one the server has already aged out.
  defp connect(socket) do
    connection =
      socket.connection
      |> Connection.put_endpoint(socket.connection.uri, headers(socket))
      |> Connection.put_reconnect_after_msec(Client.reconnect_backoff())

    Logger.info("[NervesHubLink] connecting to #{connection.uri.host}")

    case Connection.connect(connection) do
      {:ok, connection} ->
        put_connection(socket, connection)

      # Nothing is listening for this connection, so no event will report it
      # failing; the disconnect handling has to be run here.
      {:error, reason, connection} ->
        socket |> put_connection(connection) |> disconnected({:error, reason})
    end
  end

  defp headers(socket) do
    config = socket.config

    case Configurator.fetch_configurator() do
      SharedSecret -> SharedSecret.headers(config, socket.signing_time_hint)
      _ -> config.socket[:headers] || []
    end
  end

  defp handle_connect(%State{config: config} = socket) do
    Logger.info("[NervesHubLink] connection to #{config.socket[:url].host} succeeded")

    currently_downloading_uuid = UpdateManager.currently_downloading_uuid()

    device_join_params =
      socket.params
      |> Map.put("currently_downloading_uuid", currently_downloading_uuid)
      |> Map.put("meta", %{
        "firmware_auto_revert_detected" => Client.firmware_auto_revert_detected?(),
        "firmware_validated" => Client.firmware_validated?()
      })

    socket =
      %{socket | params: device_join_params, redirect_count: 0}
      |> join(@device_topic, device_join_params)
      |> maybe_join_console()
      |> schedule_heartbeat()

    Alarms.clear_alarm(NervesHubLink.Disconnected)

    Client.connected()

    socket = schedule_firmware_validation_status_check(socket)

    {:ok, socket}
  end

  defp handle_join(@device_topic, _reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Device channel")

    send(self(), :get_network_interface)

    {:ok, socket}
  end

  defp handle_join(@console_topic, _reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Console channel")
    {:ok, socket}
  end

  defp handle_join(@extensions_topic, extensions, socket) do
    Extensions.attach(extensions)
    Logger.debug("[#{inspect(__MODULE__)}] Joined Extensions channel")
    {:ok, socket}
  end

  @impl GenServer
  def handle_call({:check_connection, :device}, _from, socket) do
    {:reply, joined?(socket, @device_topic), socket}
  end

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
    {:reply, socket.iex_pid != nil, socket}
  end

  def handle_call(:update_mode, _from, socket) do
    {:reply, socket.update_mode, socket}
  end

  def handle_call(:managed_updates_allowed?, _from, socket) do
    {:reply, socket.managed_updates_allowed, socket}
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
    {result, socket} = push_message(socket, topic, event, payload)

    {:reply, result, socket}
  end

  def handle_call({:send_file, file_path}, _from, socket) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size < 10_485_760 ->
        {:ok, uploader_pid} = UploadFile.start_link(file_path, self())
        {:reply, :ok, %{socket | uploader_pid: uploader_pid}}

      {:ok, _} ->
        {:reply, {:error, :too_large}, socket}

      {:error, posix} ->
        {:reply, {:error, posix}, socket}
    end
  end

  def handle_call({:start_uploading, filename}, _from, socket) do
    if socket.uploader_pid do
      socket = push(socket, @console_topic, "file-data/start", %{filename: filename})

      {:reply, :ok, socket}
    else
      {:reply, :error, socket}
    end
  end

  def handle_call({:upload_data, filename, index, chunk}, _from, socket) do
    if socket.uploader_pid do
      socket =
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
    if socket.uploader_pid do
      socket = push(socket, @console_topic, "file-data/stop", %{filename: filename})

      {:reply, :ok, %{socket | uploader_pid: nil}}
    else
      {:reply, :error, socket}
    end
  end

  def handle_call(:cancel_upload, _from, socket) do
    if socket.uploader_pid do
      true = Process.exit(socket.uploader_pid, :kill)
      {:reply, :ok, socket}
    else
      {:reply, :error, socket}
    end
  end

  @impl GenServer
  def handle_cast(:reconnect, socket) do
    # Closing is silent by design - the caller already knows - so the
    # disconnect handling, and with it the next connection, is run from here.
    socket =
      socket
      |> put_connection(Connection.close(socket.connection))
      |> disconnected(:client_disconnect_requested)

    {:noreply, socket}
  end

  def handle_cast({:send_update_status, {stage, progress}}, socket)
      when stage in [:downloading, :updating] do
    {:noreply, push(socket, @device_topic, "fwup_progress", %{stage: stage, value: progress})}
  end

  def handle_cast({:send_update_status, status}, socket) do
    payload =
      case status do
        :received ->
          %{status: :received}

        {:started, downloader_network_interface} ->
          %{status: :started, downloader_network_interface: downloader_network_interface}

        :completed ->
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

    socket =
      if status == :completed do
        # Make sure older versions of Hub get the final 100% message
        push(socket, @device_topic, "fwup_progress", %{stage: :updating, value: 100})
      else
        socket
      end

    {:noreply, push(socket, @device_topic, "status_update", payload)}
  end

  ##
  # Device API messages
  #
  defp handle_message(@device_topic, "fwup_public_keys", params, socket) do
    config =
      update_public_keys(
        socket.config,
        :fwup_public_keys,
        params["keys"],
        "firmware"
      )

    {:ok, %{socket | config: config}}
  end

  defp handle_message(@device_topic, "archive_public_keys", params, socket) do
    config =
      update_public_keys(
        socket.config,
        :archive_public_keys,
        params["keys"],
        "archive"
      )

    {:ok, %{socket | config: config}}
  end

  defp handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warning("[NervesHubLink] Reboot Request from NervesHub")
    socket = push(socket, @device_topic, "rebooting", %{})
    # TODO: Maybe allow delayed reboot
    Client.initiate_reboot()
    {:ok, socket}
  end

  defp handle_message(@device_topic, "identify", _params, socket) do
    Client.identify()
    {:ok, socket}
  end

  defp handle_message(@device_topic, "scripts/run", params, socket) do
    # See related handle_info for pushing back the script result
    :ok = SupportScriptsManager.start_task(params["ref"], params["text"], params["timeout"])
    {:ok, socket}
  end

  defp handle_message(@device_topic, "archive", params, socket) do
    {:ok, info} = ArchiveInfo.parse(params)
    _ = ArchiveManager.apply_archive(info, socket.config.archive_public_keys)
    {:ok, socket}
  end

  defp handle_message(@device_topic, "update", update, socket) do
    case UpdateInfo.parse(update) do
      {:ok, %UpdateInfo{} = info} ->
        _ = UpdateManager.apply_update(info, socket.config.fwup_public_keys)
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

  defp handle_message(@device_topic, "update_mode", params, socket) do
    socket =
      %{
        socket
        | update_mode: parse_update_mode(params["mode"]),
          managed_updates_allowed: params["managed_updates_allowed"] == true
      }

    result =
      case params["error"] do
        nil -> :ok
        error -> {:error, update_request_error(error)}
      end

    {:ok, resolve_update_request(socket, :set_update_mode, result)}
  end

  defp handle_message(@device_topic, "update_available", params, socket) do
    result =
      {:ok,
       %{
         available?: params["available"] == true,
         firmware_meta: params["firmware_meta"]
       }}

    {:ok, resolve_update_request(socket, :check_for_update, result)}
  end

  defp handle_message(@device_topic, "update_rejected", params, socket) do
    result =
      case {params["reason"], params["delay_for"]} do
        {"busy", delay} when is_integer(delay) -> {:error, {:busy, delay}}
        {reason, _} -> {:error, update_request_error(reason)}
      end

    {:ok, resolve_update_request(socket, :start_update, result)}
  end

  # The platform's half of the negotiation: which extensions it has, and which
  # versions of each. Offering only what it named means this device never
  # declares a version nothing can serve, and never declares an extension an
  # operator has switched off.
  defp handle_message(@device_topic, "extensions:get", payload, socket) do
    {:ok, join(socket, @extensions_topic, Extensions.offer(payload["extensions"]))}
  end

  ##
  # Console API messages
  #
  defp handle_message(@console_topic, "restart", _payload, socket) do
    Logger.warning("[#{inspect(__MODULE__)}] Restarting IEx process from web request")

    socket = push(socket, @console_topic, "up", %{data: "\r*** Restarting IEx ***\r"})

    socket =
      socket
      |> stop_iex()
      |> start_iex()

    {:ok, set_iex_timer(socket)}
  end

  defp handle_message(@console_topic, message, payload, %State{iex_pid: nil} = socket) do
    handle_message(@console_topic, message, payload, start_iex(socket))
  end

  defp handle_message(@console_topic, "dn", %{"data" => data}, socket) do
    _ = ExTTY.send_text(socket.iex_pid, data)
    {:ok, set_iex_timer(socket)}
  end

  defp handle_message(
         @console_topic,
         "window_size",
         %{"height" => height, "width" => width},
         socket
       ) do
    _ = ExTTY.window_change(socket.iex_pid, width, height)
    {:ok, set_iex_timer(socket)}
  end

  defp handle_message(@console_topic, "file-data/start", params, socket) do
    :ok = File.mkdir_p!(socket.data_path)
    path = Path.join(socket.data_path, params["filename"])
    _ = File.rm_rf!(path)
    :ok = File.touch!(path)
    {:ok, socket}
  end

  defp handle_message(@console_topic, "file-data", params, socket) do
    path = Path.join(socket.data_path, params["filename"])

    _res =
      File.open!(path, [:append], fn fd ->
        chunk = Base.decode64!(params["data"])
        IO.binwrite(fd, chunk)
      end)

    {:ok, socket}
  end

  defp handle_message(@console_topic, "file-data/stop", _params, socket) do
    {:ok, socket}
  end

  defp handle_message(@extensions_topic, event, payload, socket) do
    Extensions.handle_event(event, payload)
    {:ok, socket}
  end

  ##
  # Unknown message
  #
  defp handle_message(topic, event, _params, socket) do
    Logger.warning("Unknown message (\"#{topic}:#{event}\") received")

    {:ok, socket}
  end

  @impl GenServer
  def handle_info(:connect_check_network_availability, socket) do
    uri = URI.parse(socket.config.socket[:url])

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
      socket = push(socket, @device_topic, "firmware_validated", %{})

      {:noreply, %{socket | firmware_validation_timer: nil}}
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

    {:noreply, push(socket, @device_topic, "scripts/run", payload)}
  end

  def handle_info({:tty_data, data}, socket) do
    socket = push(socket, @console_topic, "up", %{data: data})

    {:noreply, set_iex_timer(socket)}
  end

  def handle_info({:EXIT, iex_pid, reason}, %State{iex_pid: iex_pid} = socket) do
    msg = "Remote IEx stopped: #{inspect(reason)}"
    socket = push(socket, @console_topic, "up", %{data: "\r******* #{msg} *******\r"})
    Logger.warning("[NervesHubLink] #{msg}")

    socket =
      socket
      |> start_iex()
      |> set_iex_timer()

    {:noreply, socket}
  end

  def handle_info(
        {:EXIT, uploader_pid, :killed},
        %State{uploader_pid: uploader_pid} = socket
      ) do
    Logger.info("[#{inspect(__MODULE__)}] Upload cancelled")

    {:noreply, %{socket | uploader_pid: nil}}
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

    socket = push(socket, @console_topic, "up", %{data: msg})

    {:noreply, stop_iex(socket)}
  end

  def handle_info(:get_network_interface, socket) do
    case network_interface(socket) do
      interface when is_binary(interface) ->
        {:noreply,
         push(socket, @device_topic, "report_network_interface", %{interface: interface})}

      result ->
        Logger.warning(
          "[NervesHubLink] Could not determine network interface: #{inspect(result)}"
        )

        Process.send_after(self(), :get_network_interface, 60_000)
        {:noreply, socket}
    end
  end

  def handle_info(:connect, socket) do
    {:noreply, connect(socket)}
  end

  def handle_info({:rejoin, topic}, socket) do
    {:noreply, rejoin_now(socket, topic)}
  end

  def handle_info(:heartbeat, socket) do
    case Connection.send_heartbeat(socket.connection) do
      {:ok, connection} ->
        {:noreply, socket |> put_connection(connection) |> schedule_heartbeat()}

      # An unanswered heartbeat has closed the connection, and nothing arrived
      # from the network to say so, so this is where it gets reported.
      {:error, reason, connection} ->
        {:noreply, socket |> put_connection(connection) |> disconnected(reason)}
    end
  end

  # Anything left is either the connection's or nobody's. The connection claims
  # what belongs to it and says so when a message is not its own, which is what
  # keeps the clauses above working.
  def handle_info(message, socket) do
    case Connection.handle_transport(socket.connection, message) do
      {:ok, connection, events} ->
        {:noreply, socket |> put_connection(connection) |> apply_events(events)}

      :unknown ->
        Logger.warning("[#{inspect(__MODULE__)}] Unhandled handle_info: #{inspect(message)}")

        {:noreply, socket}
    end
  end

  defp handle_reply(ref, {:error, "detach"}, socket) do
    Extensions.detach(ref)
    {:ok, socket}
  end

  defp handle_reply(ref, reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Reply to #{ref} : #{inspect(reply)}")

    {:ok, socket}
  end

  defp handle_topic_close(topic, reason, socket) when reason != :left do
    if topic == @device_topic do
      _ = Client.handle_error(reason)
    end

    rejoin(socket, topic)
  end

  defp handle_disconnect(reason, socket) do
    _ = Client.handle_error(reason)
    :alarm_handler.set_alarm({NervesHubLink.Disconnected, [reason: reason]})

    socket =
      socket
      |> cancel_heartbeat()
      |> fail_pending_update_requests()

    # When the failed upgrade response carried a `Date` header, the next
    # attempt signs with that time instead of the device clock, which recovers
    # a device whose RTC or NTP is not trustworthy yet. The signing itself
    # happens in `connect/1`, so what is kept here is only the hint.
    socket = %{socket | signing_time_hint: SharedSecret.server_time_hint(reason)}

    handle_redirect(socket, reason)
  end

  # A 3xx answer to the upgrade request is NervesHub pointing this device at
  # another host. Anything else is an ordinary disconnect, and just reconnects.
  defp handle_redirect(socket, reason) do
    with {:ok, status, headers} <- upgrade_failure(reason),
         true <- redirect_status?(status) do
      follow_redirect(socket, headers, reason)
    else
      _ -> reconnect(socket)
    end
  end

  # Past this many hops the server is redirecting in a loop, so the redirect is
  # not followed - but the device still has to keep trying, at backoff pace and
  # against the URL it has. Going quiet instead leaves it off the air with
  # nothing running that would ever bring it back.
  defp follow_redirect(%State{redirect_count: count} = socket, _headers, reason)
       when count >= @max_redirects do
    Logger.error("[NervesHubLink] maximum redirect count reached : #{inspect(reason)}")

    reconnect(socket)
  end

  defp follow_redirect(socket, headers, _reason) do
    case redirect_uri(socket.connection.uri, headers) do
      {:ok, uri} ->
        Logger.info("[NervesHubLink] redirect received : #{URI.to_string(uri)}")

        connection = Connection.put_endpoint(socket.connection, uri, socket.connection.headers)

        reconnect(%{
          socket
          | connection: connection,
            redirect_count: socket.redirect_count + 1
        })

      :error ->
        # A 3xx with nothing to redirect to. Nothing to follow, so this is
        # treated as the plain disconnect it effectively is.
        Logger.error("[NervesHubLink] redirect received without a usable location header")
        reconnect(socket)
    end
  end

  # The one place that knows how a failed HTTP upgrade is reported to us.
  # Everything else works from `{:ok, status, headers}`.
  @doc false
  @spec upgrade_failure(term()) :: {:ok, non_neg_integer(), [{binary(), binary()}]} | :error
  def upgrade_failure(
        {:upgrade_failure, %UpgradeFailureError{status_code: status, headers: headers}}
      )
      when is_integer(status) and is_list(headers) do
    {:ok, status, headers}
  end

  def upgrade_failure(_reason), do: :error

  defp redirect_status?(status), do: status >= 300 and status < 400

  # `Location` is allowed to be relative, so it is merged onto the URL the
  # device just tried. The redirect answers an HTTP request and so names an
  # http(s) scheme, but the next attempt is still a websocket upgrade.
  @doc false
  @spec redirect_uri(URI.t(), [{binary(), binary()}]) :: {:ok, URI.t()} | :error
  def redirect_uri(%URI{} = current_uri, headers) when is_list(headers) do
    case List.keyfind(headers, "location", 0) do
      {_name, location} when is_binary(location) and location != "" ->
        {:ok, current_uri |> URI.merge(location) |> websocket_scheme()}

      _ ->
        :error
    end
  end

  defp websocket_scheme(%URI{scheme: "http"} = uri), do: %{uri | scheme: "ws"}
  defp websocket_scheme(%URI{scheme: "https"} = uri), do: %{uri | scheme: "wss"}
  defp websocket_scheme(%URI{} = uri), do: uri

  @impl GenServer
  def terminate(_reason, socket) do
    _ = Connection.close(socket.connection)

    :ok
  end

  ##
  # The connection
  #

  # Each event the connection produced, in the order it happened, handed to the
  # function that handles it.
  defp apply_events(socket, events), do: Enum.reduce(events, socket, &apply_event/2)

  defp apply_event(:connected, socket), do: unwrap(handle_connect(socket))

  defp apply_event({:joined, topic, reply}, socket), do: unwrap(handle_join(topic, reply, socket))

  defp apply_event({:join_failed, topic, reason}, socket),
    do: unwrap(handle_topic_close(topic, reason, socket))

  defp apply_event({:topic_closed, topic, reason}, socket),
    do: unwrap(handle_topic_close(topic, reason, socket))

  # The server closing a topic normally is not something this device asks for,
  # and there is nothing it needs to do about it beyond noticing.
  defp apply_event({:topic_left, topic}, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] #{topic} was closed by NervesHub")

    socket
  end

  defp apply_event({:message, topic, event, payload}, socket),
    do: unwrap(handle_message(topic, event, payload, socket))

  defp apply_event({:reply, ref, reply}, socket), do: unwrap(handle_reply(ref, reply, socket))

  defp apply_event({:disconnected, reason}, socket), do: disconnected(socket, reason)

  defp unwrap({:ok, %State{} = socket}), do: socket

  # Runs what a `{:disconnected, reason}` event would have run, for the cases
  # where the connection is lost without anything arriving to announce it: a
  # write that failed, an unanswered heartbeat, a connection that never opened.
  defp disconnected(socket, reason), do: unwrap(handle_disconnect(reason, socket))

  defp put_connection(socket, connection), do: %{socket | connection: connection}

  defp join(socket, topic, params) do
    case Connection.join(socket.connection, topic, params) do
      {:ok, connection} ->
        put_connection(socket, connection)

      {:error, reason, connection} ->
        Logger.warning("[NervesHubLink] could not join #{topic} : #{inspect(reason)}")

        put_connection(socket, connection)
    end
  end

  # Pushes and reports what happened, for the callers that need the ref or the
  # error. Everything else uses `push/4`.
  defp push_message(socket, topic, event, payload) do
    case Connection.push(socket.connection, topic, event, payload) do
      {:ok, ref, connection} ->
        {{:ok, ref}, put_connection(socket, connection)}

      {:error, reason, connection} ->
        socket = put_connection(socket, connection)

        # A write that failed has already taken the connection with it, and
        # nothing arrived from the network to announce that, so the disconnect
        # handling runs from here or not at all. It belongs here rather than in
        # `push/4` so that the callers who want the error get it too.
        socket =
          if Connection.connected?(socket.connection) do
            socket
          else
            disconnected(socket, reason)
          end

        {{:error, reason}, socket}
    end
  end

  defp push(socket, topic, event, payload) do
    case push_message(socket, topic, event, payload) do
      {{:ok, _ref}, socket} ->
        socket

      {{:error, reason}, socket} ->
        Logger.warning("[NervesHubLink] could not send #{topic}:#{event} : #{inspect(reason)}")

        socket
    end
  end

  # The delay comes from the connection's own backoff, so repeated failures back
  # off and a connection that succeeds starts the next one over from the
  # shortest wait.
  defp reconnect(socket) do
    {delay, connection} = Connection.reconnect_delay(socket.connection)

    _ = Process.send_after(self(), :connect, delay)

    {:ok, put_connection(socket, connection)}
  end

  defp rejoin(socket, topic) do
    {delay, connection} = Connection.rejoin_delay(socket.connection, topic)

    _ = Process.send_after(self(), {:rejoin, topic}, delay)

    {:ok, put_connection(socket, connection)}
  end

  defp rejoin_now(socket, topic) do
    case Connection.rejoin(socket.connection, topic) do
      {:ok, connection} ->
        put_connection(socket, connection)

      # Not worth retrying from here: losing the connection schedules a
      # reconnect, and the topics are joined again when that succeeds.
      {:error, reason, connection} ->
        Logger.warning("[NervesHubLink] could not rejoin #{topic} : #{inspect(reason)}")

        put_connection(socket, connection)
    end
  end

  # Phoenix drops a connection that has been quiet for 60 seconds, and an
  # unanswered one is how a connection that is dead without either end noticing
  # gets found out.
  defp schedule_heartbeat(socket) do
    case socket.config.heartbeat_interval_msec do
      interval when is_integer(interval) and interval > 0 ->
        socket = cancel_heartbeat(socket)

        %{socket | heartbeat_timer: Process.send_after(self(), :heartbeat, interval)}

      _ ->
        socket
    end
  end

  defp cancel_heartbeat(socket) do
    maybe_cancel_timer(socket.heartbeat_timer)

    %{socket | heartbeat_timer: nil}
  end

  ##
  # State
  #

  defp joined?(%State{} = socket, topic), do: Connection.joined?(socket.connection, topic)

  defp connected?(%State{} = socket), do: Connection.connected?(socket.connection)

  # A delay list may be configured as a bare number, and has to have at least
  # one entry for the backoff to index into.
  defp backoff_list(nil, default), do: [default]

  defp backoff_list(delays, default) do
    case List.flatten([delays]) do
      [] -> [default]
      delays -> delays
    end
  end

  # The connection is held right here, so this is a plain read rather than the
  # best-effort look into another process's state it used to be.
  defp network_interface(socket) do
    case Connection.mint_socket(socket.connection) do
      nil -> nil
      mint_socket -> NetworkInterface.from_socket(mint_socket)
    end
  end

  # Falling back to JSON rather than raising: a serializer the device can't use
  # is a configuration mistake, and refusing to connect over it would leave the
  # device unreachable, including for the update that would fix the mistake.
  @doc false
  @spec serializer_for(Configurator.Config.t()) :: {URI.t(), module()}
  def serializer_for(%{serializer: :msgpack} = config) do
    if Code.ensure_loaded?(NervesHubLink.Connection.Serializer.MsgPack) do
      {url_with_vsn(config, @msgpack_vsn), NervesHubLink.Connection.Serializer.MsgPack}
    else
      Logger.error(
        "[NervesHubLink] the :msgpack serializer needs the :msgpax dependency, using JSON instead"
      )

      json_serializer(config)
    end
  end

  def serializer_for(%{serializer: :json} = config), do: json_serializer(config)

  def serializer_for(config) do
    Logger.error(
      "[NervesHubLink] unknown serializer #{inspect(config.serializer)}, using JSON instead"
    )

    json_serializer(config)
  end

  defp json_serializer(config) do
    {url_with_vsn(config, @json_vsn), Connection.Serializer.JSON}
  end

  # The `vsn` we ask for has to be the one matching the serializer we chose, so
  # it is set here rather than left to a default further down, and it overrides
  # a `vsn` in a configured URL. Any other query parameters are kept.
  defp url_with_vsn(config, vsn) do
    url = config.socket[:url]

    query =
      (url.query || "")
      |> URI.decode_query()
      |> Map.put("vsn", vsn)
      |> URI.encode_query()

    %{url | query: query}
  end

  # A device-initiated request is answered by a separate message rather than a
  # reply to the push, so the caller is parked here until that message arrives —
  # or until the timeout does, so a lost answer cannot leak a stuck caller.
  defp start_update_request(socket, kind, from, event, payload) do
    cond do
      not joined?(socket, @device_topic) ->
        {:reply, {:error, :disconnected}, socket}

      Map.has_key?(socket.pending_update_requests, kind) ->
        {:reply, {:error, :already_in_progress}, socket}

      true ->
        case push_message(socket, @device_topic, event, payload) do
          {{:ok, _ref}, socket} ->
            timer =
              Process.send_after(self(), {:update_request_timeout, kind}, @update_request_timeout)

            pending = Map.put(socket.pending_update_requests, kind, {from, timer})

            {:noreply, %{socket | pending_update_requests: pending}}

          {{:error, reason}, socket} ->
            {:reply, {:error, reason}, socket}
        end
    end
  end

  # Nothing can answer these once the connection has gone, and waiting out the
  # timeout would report one as a timeout rather than what it was.
  defp fail_pending_update_requests(%State{pending_update_requests: pending} = socket)
       when map_size(pending) == 0,
       do: socket

  defp fail_pending_update_requests(socket) do
    Enum.each(socket.pending_update_requests, fn {_kind, {from, timer}} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :disconnected})
    end)

    %{socket | pending_update_requests: %{}}
  end

  defp resolve_update_request(socket, kind, result) do
    case Map.pop(socket.pending_update_requests, kind) do
      {nil, _pending} ->
        socket

      {{from, timer}, pending} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, result)
        %{socket | pending_update_requests: pending}
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
    ssl_opts = if config.socket[:url].scheme == "wss", do: config.ssl, else: []

    base =
      case Keyword.merge(send_timeout_opts(config), ssl_opts) do
        [] -> [protocols: [:http1]]
        transport_opts -> [protocols: [:http1], transport_opts: transport_opts]
      end

    merge_http_opts(base, config.socket[:http_opts] || [])
  end

  # Bounds how long a write to the socket may block. Without this a stalled
  # write - a server that has stopped reading, so the send buffer never
  # drains - blocks the connection indefinitely, and takes the heartbeat that
  # would otherwise notice the dead link down with it. The device then sits
  # there believing it is connected until something reboots it.
  #
  # `send_timeout_close` closes the socket when the timeout trips, so the
  # ordinary disconnect and reconnect path takes over.
  defp send_timeout_opts(%{send_timeout_msec: timeout}) when timeout in [0, nil], do: []

  defp send_timeout_opts(%{send_timeout_msec: timeout}),
    do: [send_timeout: timeout, send_timeout_close: true]

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
    if socket.params["meta"]["firmware_validated"] == true do
      Logger.debug("[NervesHubLink] Firmware validated and information sent during connection")
      socket
    else
      maybe_cancel_timer(socket.firmware_validation_timer)

      timer =
        Process.send_after(
          self(),
          :firmware_validation_status_check,
          @firmware_validation_check_interval
        )

      %{socket | firmware_validation_timer: timer}
    end
  end

  # The console only needs to know which protocol versions it is talking to.
  # The rest of the join params describe the device and its firmware, and the
  # device connection has already sent them.
  @console_join_params ["console_version", "device_api_version"]

  defp maybe_join_console(socket) do
    if socket.remote_iex do
      join(socket, @console_topic, Map.take(socket.params, @console_join_params))
    else
      socket
    end
  end

  defp set_iex_timer(socket) do
    timeout = socket.config.remote_iex_timeout * 1000

    maybe_cancel_timer(socket.iex_timer)

    %{socket | iex_timer: Process.send_after(self(), :iex_timeout, timeout)}
  end

  defp start_iex(socket) do
    shell_opts = [[dot_iex_path: dot_iex_path()]]
    {:ok, iex_pid} = ExTTY.start_link(handler: self(), type: :elixir, shell_opts: shell_opts)
    %{socket | iex_pid: iex_pid}
  end

  defp dot_iex_path() do
    [".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
  end

  defp stop_iex(%State{iex_pid: nil} = socket), do: socket

  defp stop_iex(%State{iex_pid: iex} = socket) do
    _ = Process.unlink(iex)
    GenServer.stop(iex, :normal, 10_000)
    %{socket | iex_pid: nil}
  end

  defp maybe_cancel_timer(nil), do: :ok

  defp maybe_cancel_timer(pid) do
    _ = Process.cancel_timer(pid)
    :ok
  end
end
