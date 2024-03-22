defmodule NervesHubLink.Socket do
  @moduledoc false

  use Slipstream

  require Logger

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator.SharedSecret
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UploadFile

  defmodule State do
    @type t :: %__MODULE__{
            channel: pid(),
            connected?: boolean(),
            params: map(),
            socket: pid(),
            topic: String.t()
          }

    defstruct socket: nil,
              topic: "device",
              channel: nil,
              params: %{},
              connected?: false
  end

  @console_topic "console"
  @device_topic "device"

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  def send_update_progress(progress) do
    GenServer.cast(__MODULE__, {:send_update_progress, progress})
  end

  def send_update_status(status) do
    GenServer.cast(__MODULE__, {:send_update_status, status})
  end

  def check_connection(type) do
    GenServer.call(__MODULE__, {:check_connection, type})
  end

  @spec send_file(Path.t()) :: :ok | {:error, :too_large | File.posix()}
  def send_file(file_path) do
    GenServer.call(__MODULE__, {:send_file, file_path})
  end

  @doc false
  def start_uploading(pid, filename) do
    GenServer.call(pid, {:start_uploading, filename})
  end

  @doc false
  def upload_data(pid, filename, index, chunk) do
    GenServer.call(pid, {:upload_data, filename, index, chunk})
  end

  @doc false
  def finish_uploading(pid, filename) do
    GenServer.call(pid, {:finish_uploading, filename})
  end

  @doc """
  Cancel an ongoing upload

  Escape hatch for uploading files via the console, kill the upload
  process to stop uploading.
  """
  def cancel_upload() do
    GenServer.call(__MODULE__, :cancel_upload)
  end

  @doc """
  Return whether an IEx or other console session is active
  """
  @spec console_active?() :: boolean()
  def console_active?() do
    GenServer.call(__MODULE__, :console_active?)
  end

  @impl Slipstream
  def init(config) do
    :alarm_handler.set_alarm({NervesHubLink.Disconnected, []})
    rejoin_after = Application.get_env(:nerves_hub_link, :rejoin_after, 5_000)

    opts = [
      mint_opts: [protocols: [:http1], transport_opts: config.ssl],
      headers: config.socket[:headers] || [],
      uri: config.socket[:url],
      rejoin_after_msec: [rejoin_after],
      reconnect_after_msec: config.socket[:reconnect_after_msec]
    ]

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
      |> connect!(opts)

    Process.flag(:trap_exit, true)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    currently_downloading_uuid = UpdateManager.currently_downloading_uuid()

    device_join_params =
      socket.assigns.params
      |> Map.put("currently_downloading_uuid", currently_downloading_uuid)

    socket =
      socket
      |> join(@device_topic, device_join_params)
      |> maybe_join_console()
      |> assign(connected_at: System.monotonic_time(:millisecond))

    :alarm_handler.clear_alarm(NervesHubLink.Disconnected)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(@device_topic, reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Device channel")
    _ = handle_join_reply(reply)
    {:ok, assign(socket, joined_at: System.monotonic_time(:millisecond))}
  end

  def handle_join(@console_topic, _reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Console channel")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_call({:check_connection, :console}, _from, socket) do
    {:reply, joined?(socket, @console_topic), socket}
  end

  def handle_call({:check_connection, :device}, _from, socket) do
    {:reply, joined?(socket, @device_topic), socket}
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

  @impl Slipstream
  def handle_cast(:reconnect, socket) do
    # See handle_disconnect/2 for the reconnect call once the connection is
    # closed.
    {:noreply, disconnect(socket)}
  end

  def handle_cast({:send_update_progress, progress}, socket) do
    _ = push(socket, @device_topic, "fwup_progress", %{value: progress})
    {:noreply, socket}
  end

  def handle_cast({:send_update_status, status}, socket) do
    _ = push(socket, @device_topic, "status_update", %{status: status})
    {:noreply, socket}
  end

  @impl Slipstream
  ##
  # Device API messages
  #
  def handle_message(@device_topic, "fwup_public_keys", params, socket) do
    Logger.info(
      "Updating fwup public keys from NervesHubLink - #{Enum.count(params["keys"])} key(s) received"
    )

    config = %{socket.assigns.config | fwup_public_keys: params["keys"]}

    {:ok, assign(socket, config: config)}
  end

  def handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warning("Reboot Request from NervesHubLink")
    _ = push(socket, @device_topic, "rebooting", %{})
    # TODO: Maybe allow delayed reboot
    Nerves.Runtime.reboot()
    {:ok, socket}
  end

  def handle_message(@device_topic, "identify", _params, socket) do
    Client.identify()
    {:ok, socket}
  end

  def handle_message(@device_topic, "archive", params, socket) do
    {:ok, info} = NervesHubLink.Message.ArchiveInfo.parse(params)
    _ = ArchiveManager.apply_archive(info)
    {:ok, socket}
  end

  def handle_message(@device_topic, "update", update, socket) do
    case NervesHubLink.Message.UpdateInfo.parse(update) do
      {:ok, %NervesHubLink.Message.UpdateInfo{} = info} ->
        _ = UpdateManager.apply_update(info)
        {:ok, socket}

      error ->
        Logger.error("Error parsing update data: #{inspect(update)} error: #{inspect(error)}")
        {:ok, socket}
    end
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

    {:ok, _res} =
      File.open!(path, [:append], fn fd ->
        chunk = Base.decode64!(params["data"])
        IO.binwrite(fd, chunk)
      end)

    {:ok, socket}
  end

  def handle_message(@console_topic, "file-data/stop", _params, socket) do
    {:ok, socket}
  end

  @impl Slipstream
  def handle_info({:tty_data, data}, socket) do
    _ = push(socket, @console_topic, "up", %{data: data})
    {:noreply, set_iex_timer(socket)}
  end

  def handle_info({:EXIT, iex_pid, reason}, %{assigns: %{iex_pid: iex_pid}} = socket) do
    msg = "\r******* Remote IEx stopped: #{inspect(reason)} *******\r"
    _ = push(socket, @console_topic, "up", %{data: msg})
    Logger.warning(msg)

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
  def handle_topic_close(topic, reason, socket) when reason != :left do
    if topic == @device_topic do
      _ = Client.handle_error(reason)
    end

    rejoin(socket, topic, socket.assigns.params)
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    _ = Client.handle_error(reason)
    :alarm_handler.set_alarm({NervesHubLink.Disconnected, [reason: reason]})
    channel_config = %{socket.channel_config | reconnect_after_msec: Client.reconnect_backoff()}

    channel_config =
      case Application.get_env(:nerves_hub_link, :configurator) do
        SharedSecret ->
          # TODO: I don't know when reconnect/1 actually gets valudated. It could be that
          # the signature we create here will be too old before the headers are used
          # in a connection attempt again
          headers = SharedSecret.headers(socket.assigns.config)
          %{channel_config | headers: headers}

        _ ->
          channel_config
      end

    socket = %{socket | channel_config: channel_config}

    reconnect(socket)
  end

  @impl Slipstream
  def terminate(_reason, socket) do
    disconnect(socket)
  end

  defp handle_join_reply(%{"firmware_url" => url} = update) when is_binary(url) do
    case NervesHubLink.Message.UpdateInfo.parse(update) do
      {:ok, %NervesHubLink.Message.UpdateInfo{} = info} ->
        UpdateManager.apply_update(info)

      error ->
        Logger.error("Error parsing update data: #{inspect(update)} error: #{inspect(error)}")
        :noop
    end
  end

  defp handle_join_reply(_), do: :noop

  defp maybe_join_console(socket) do
    if socket.assigns.remote_iex do
      join(socket, @console_topic, socket.assigns.params)
    else
      socket
    end
  end

  defp set_iex_timer(socket) do
    timeout = Application.get_env(:nerves_hub_link, :remote_iex_timeout, 300) * 1000
    old_timer = socket.assigns[:iex_timer]

    _ = if old_timer, do: Process.cancel_timer(old_timer)

    assign(socket, iex_timer: Process.send_after(self(), :iex_timeout, timeout))
  end

  defp start_iex(socket) do
    shell_opts = [[dot_iex_path: dot_iex_path()]]
    {:ok, iex_pid} = ExTTY.start_link(handler: self(), type: :elixir, shell_opts: shell_opts)
    # %{state | iex_pid: iex_pid}
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
end
