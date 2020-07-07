defmodule NervesHubLink.ConsoleChannel do
  use GenServer
  require Logger

  @moduledoc """
  Starts an IEx shell in process to allow remote console interaction

  The remote console ability is disabled by default and requires the
  `remote_iex` key to be enabled in the config:
  ```
  config :nerves_hub_link, remote_iex: true
  ```

  Once connected, shell data on the device will be pushed up the socket
  for the following events:

  The following events are supported _from_ the Server:

  * `phx_close` or `phx_error` - This will cause the channel to attempt rejoining
  every 5 seconds. You can change the rejoin timing in the config
  ```
  config :nerves_hub_link, rejoin_after: 3_000
  ```
  * `dn` - String data to send to the shell for evaluation
  * `restart` - Restart the IEx shell process
  * `window_size` - A map with `:height` and `:width` keys for resizing the terminal

  The following events are supported _from_ this client:

  * `up` - String data to be displayed to the user console frontend
  """

  alias PhoenixClient.{Channel, Message}
  alias NervesHubLink.Client

  @rejoin_after Application.get_env(:nerves_hub_link, :rejoin_after, 5_000)

  @version Mix.Project.config()[:version]

  defmodule State do
    defstruct socket: nil,
              topic: "console",
              channel: nil,
              params: [],
              iex_pid: nil
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = State.__struct__(opts)
    {:ok, iex_pid} = ExTTY.start_link(handler: self(), type: :elixir)
    send(self(), :join)

    {:ok, %{state | iex_pid: iex_pid}}
  end

  @impl true
  def handle_info(:join, %{socket: socket, topic: topic, params: params} = state) do
    params = Map.put(params, "console_version", @version)

    case Channel.join(socket, topic, params) do
      {:ok, _reply, channel} ->
        {:noreply, %{state | channel: channel}}

      _error ->
        Process.send_after(self(), :join, @rejoin_after)
        {:noreply, state}
    end
  end

  def handle_info({:tty_data, data}, state) do
    Channel.push_async(state.channel, "up", %{data: data})
    {:noreply, state}
  end

  def handle_info(%Message{event: "restart"}, state) do
    :ok = GenServer.stop(state.iex_pid, 10_000)
    {:ok, iex_pid} = ExTTY.start_link(handler: self(), type: :elixir)
    {:noreply, %{state | iex_pid: iex_pid}}
  end

  def handle_info(%Message{event: "dn", payload: %{"data" => data}}, state) do
    ExTTY.send_text(state.iex_pid, data)
    {:noreply, state}
  end

  def handle_info(%Message{event: event, payload: payload}, state)
      when event in ["phx_error", "phx_close"] do
    reason = Map.get(payload, :reason, "unknown")
    _ = Client.handle_error(reason)
    Process.send_after(self(), :join, @rejoin_after)
    {:noreply, state}
  end

  def handle_info(req, state) do
    Client.handle_error("Unhandled Console handle_info - #{inspect(req)}")
    {:noreply, state}
  end
end
