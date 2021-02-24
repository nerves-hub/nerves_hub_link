defmodule NervesHubLink.Socket do
  use Slipstream
  require Logger

  alias NervesHubLink.Client
  alias NervesHubLinkCommon.UpdateManager

  @rejoin_after Application.get_env(:nerves_hub_link, :rejoin_after, 5_000)

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

  def send_update_progress(progress) do
    GenServer.cast(__MODULE__, {:send_update_progress, progress})
  end

  def send_update_status(status) do
    GenServer.cast(__MODULE__, {:send_update_status, status})
  end

  def check_connection(type) do
    GenServer.call(__MODULE__, {:check_connection, type})
  end

  @impl Slipstream
  def init(config) do
    opts = [
      gun_open_options: %{transport: :tls, transport_opts: config.ssl},
      uri: config.socket[:url],
      rejoin_after_msec: [@rejoin_after]
    ]

    socket =
      new_socket()
      |> assign(params: config.params)
      |> assign(remote_iex: config.remote_iex)
      |> assign(iex_pid: nil)
      |> assign(iex_timer: nil)
      |> connect!(opts)

    Process.flag(:trap_exit, true)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    socket =
      socket
      |> join(@device_topic, socket.assigns.params)
      |> maybe_join_console()

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(@device_topic, reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Device channel")
    NervesHubLink.Connection.connected()
    _ = handle_join_reply(reply)
    {:ok, socket}
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

  @impl Slipstream
  def handle_cast({:send_update_progress, progress}, socket) do
    push!(socket, @device_topic, "fwup_progress", %{value: progress})
    {:noreply, socket}
  end

  def handle_cast({:send_update_status, status}, socket) do
    push!(socket, @device_topic, "status_update", %{status: status})
    {:noreply, socket}
  end

  @impl Slipstream
  ##
  # Device API messages
  #
  def handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warn("Reboot Request from NervesHubLink")
    push!(socket, @device_topic, "rebooting", %{})
    # TODO: Maybe allow delayed reboot
    Nerves.Runtime.reboot()
    {:ok, socket}
  end

  def handle_message(@device_topic, "update", update, socket) do
    _ = UpdateManager.apply_update(update)
    {:ok, socket}
  end

  ##
  # Console API messages
  #
  def handle_message(@console_topic, "restart", _payload, socket) do
    Logger.warn("[#{inspect(__MODULE__)}] Restarting IEx process from web request")

    push!(socket, @console_topic, "up", %{data: "\r*** Restarting IEx ***\r"})

    socket =
      socket
      |> stop_iex()
      |> start_iex()

    {:ok, set_iex_timer(socket)}
  end

  def handle_message(@console_topic, "dn", payload, %{assigns: %{iex_pid: nil}} = socket) do
    handle_message(@console_topic, "dn", payload, start_iex(socket))
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

  @impl Slipstream
  def handle_info({:tty_data, data}, socket) do
    push!(socket, @console_topic, "up", %{data: data})
    {:noreply, set_iex_timer(socket)}
  end

  def handle_info({:EXIT, iex_pid, reason}, %{assigns: %{iex_pid: iex_pid}} = socket) do
    msg = "\r******* Remote IEx stopped: #{inspect(reason)} *******\r"
    push!(socket, @console_topic, "up", %{data: msg})
    Logger.warn(msg)

    socket =
      socket
      |> start_iex()
      |> set_iex_timer()

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

    # Channel.push_async(socket.channel, "up", %{data: msg})
    push!(socket, @console_topic, "up", %{data: msg})

    {:noreply, stop_iex(socket)}
  end

  def handle_info(msg, socket) do
    Logger.warn("[#{inspect(__MODULE__)}] Unhandled handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) when reason != :left do
    if topic == @device_topic do
      _ = NervesHubLink.Connection.disconnected()
      _ = Client.handle_error(reason)
    end

    rejoin(socket, topic, socket.assigns.params)
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    _ = Client.handle_error(reason)
    reconnect(socket)
  end

  @impl Slipstream
  def terminate(_reason, socket) do
    _ = NervesHubLink.Connection.disconnected()
    disconnect(socket)
  end

  defp handle_join_reply(%{"firmware_url" => url} = update) when is_binary(url) do
    UpdateManager.apply_update(update)
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
    :ok = GenServer.stop(iex, 10_000)
    assign(socket, iex_pid: nil)
  end
end
