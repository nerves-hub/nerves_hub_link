defmodule NervesHubDevice.Supervisor do
  use Supervisor

  alias NervesHubDevice.{Channel, ConsoleChannel}
  alias PhoenixClient.Socket

  @moduledoc """
  Supervisor for maintaining a channel connection to a NervesHubDevice server

  This module starts the GenServers that maintain a Phoenix channel connection
  to the NervesHubDevice server and respond to update requests.  It isn't started
  automatically, so you should add it to one of your OTP application's
  supervision trees:

  ```elixir
    defmodule Example.Application do
      use Application

      def start(_type, _args) do

        opts = [strategy: :one_for_one, name: Example.Supervisor]
        children = [
          NervesHubDevice.Supervisor
        ] ++ children(@target)
        Supervisor.start_link(children, opts)
      end
    end
  ```
  """

  @doc """
  Start the NervesHubDevice supervision tree
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(socket_opts) do
    Supervisor.start_link(__MODULE__, socket_opts, name: __MODULE__)
  end

  @impl true
  def init(socket_opts) do
    socket_opts =
      Application.get_env(:nerves_hub_device, :socket, [])
      |> Keyword.merge(socket_opts)
      |> NervesHubDevice.Socket.opts()

    join_params = Nerves.Runtime.KV.get_all_active()

    children =
      [
        NervesHubDevice.Connection,
        {Socket, {socket_opts, [name: NervesHubDevice.Socket]}},
        {Channel, [socket: NervesHubDevice.Socket, topic: "device", join_params: join_params]}
      ]
      |> add_console_child(join_params)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp add_console_child(children, params) do
    if Application.get_env(:nerves_hub_device, :remote_iex, false) do
      [{ConsoleChannel, [socket: NervesHubDevice.Socket, params: params]} | children]
    else
      children
    end
  end
end
