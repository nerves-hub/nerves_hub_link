defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.{
    DeviceChannel,
    Configurator,
    Connection,
    ConsoleChannel,
    Socket,
    UpdateManager
  }

  def start(_type, _args) do
    config = Configurator.build()

    children =
      [
        Connection,
        {PhoenixClient.Socket, {config.socket, [id: Socket, name: Socket]}},
        {DeviceChannel, [socket: Socket, params: config.params]},
        UpdateManager
      ]
      |> add_console_child(config)

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end

  defp add_console_child(children, config) do
    if config.remote_iex == true do
      [{ConsoleChannel, [socket: Socket, params: config.params]} | children]
    else
      children
    end
  end
end
