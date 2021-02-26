defmodule NervesHubLink.DeviceChannel do
  use GenServer
  require Logger

  alias NervesHubLink.Client
  alias NervesHubLinkCommon.UpdateManager
  alias PhoenixClient.{Channel, Message}

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

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send_update_progress(progress) do
    GenServer.cast(__MODULE__, {:send_update_progress, progress})
  end

  def send_update_status(status) do
    GenServer.cast(__MODULE__, {:send_update_status, status})
  end

  def connected?() do
    GenServer.call(__MODULE__, :connected?)
  end

  @impl GenServer
  def init(opts) do
    send(self(), :join)
    {:ok, struct(State, opts)}
  end

  @impl GenServer
  def handle_call(:connected?, _from, %{connected?: connected?} = state) do
    {:reply, connected?, state}
  end

  @impl GenServer
  def handle_cast({:send_update_progress, progress}, state) do
    Channel.push_async(state.channel, "fwup_progress", %{value: progress})
    {:noreply, state}
  end

  def handle_cast({:send_update_status, status}, state) do
    Channel.push_async(state.channel, "status_update", %{status: status})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(%Message{event: "reboot"}, state) do
    Logger.warn("Reboot Request from NervesHubLink")
    Channel.push_async(state.channel, "rebooting", %{})
    Client.initiate_reboot()
    {:noreply, state}
  end

  def handle_info(%Message{event: "update", payload: update}, state) do
    case NervesHubLinkCommon.Message.UpdateInfo.parse(update) do
      {:ok, %NervesHubLinkCommon.Message.UpdateInfo{} = info} ->
        _ = UpdateManager.apply_update(info)
        {:noreply, state}

      error ->
        Logger.error("Error parsing update data: #{inspect(update)} error: #{inspect(error)}")
        {:noreply, state}
    end
  end

  def handle_info(%Message{event: event, payload: payload}, state)
      when event in ["phx_error", "phx_close"] do
    reason = Map.get(payload, :reason, "unknown")
    NervesHubLink.Connection.disconnected()
    _ = Client.handle_error(reason)
    Process.send_after(self(), :join, @rejoin_after)
    {:noreply, %{state | connected?: false}}
  end

  def handle_info(:join, %{socket: socket, topic: topic, params: params} = state) do
    case Channel.join(socket, topic, params) do
      {:ok, reply, channel} ->
        NervesHubLink.Connection.connected()
        _ = handle_join_reply(reply)
        {:noreply, %{state | channel: channel, connected?: true}}

      _error ->
        NervesHubLink.Connection.disconnected()
        Process.send_after(self(), :join, @rejoin_after)
        {:noreply, %{state | connected?: false}}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state), do: NervesHubLink.Connection.disconnected()

  defp handle_join_reply(%{"firmware_url" => url} = update) when is_binary(url) do
    case NervesHubLinkCommon.Message.UpdateInfo.parse(update) do
      {:ok, %NervesHubLinkCommon.Message.UpdateInfo{} = info} ->
        UpdateManager.apply_update(info)

      error ->
        Logger.error("Error parsing update data: #{inspect(update)} error: #{inspect(error)}")
        :noop
    end
  end

  defp handle_join_reply(_), do: :noop
end
