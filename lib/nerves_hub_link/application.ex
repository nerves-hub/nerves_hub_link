defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.{Channel, Connection, ConsoleChannel, Socket}

  def start(_type, _args) do
    params = Nerves.Runtime.KV.get_all_active()

    children =
      [
        Connection,
        {PhoenixClient.Socket, {Socket.opts(), [name: Socket]}},
        {Channel, [socket: Socket, topic: "device", params: params]}
      ]
      |> add_console_child(params)

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end

  defp add_console_child(children, params) do
    if Application.get_env(:nerves_hub_link, :remote_iex, false) do
      [{ConsoleChannel, [socket: Socket, params: params]} | children]
    else
      children
    end
  end
end
