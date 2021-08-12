defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.{
    DeviceChannel,
    Client,
    Configurator,
    Connection,
    ConsoleChannel,
    Socket
  }

  alias NervesHubLinkCommon.{UpdateManager, FwupConfig}

  def start(_type, _args) do
    config = Configurator.build()

    fwup_config = %FwupConfig{
      fwup_public_keys: config.fwup_public_keys,
      fwup_devpath: config.fwup_devpath,
      fwup_env: config.fwup_env,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }

    children =
      [
        {UpdateManager, fwup_config},
        Connection,
        {PhoenixClient.Socket, {config.socket, [id: Socket, name: Socket]}},
        {DeviceChannel, [socket: Socket, params: config.params]}
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
