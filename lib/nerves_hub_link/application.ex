defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.{
    Client,
    Configurator,
    Connection,
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
      update_available: &Client.update_available/1,
      deployment_info_available: &Client.deployment_info_available/1
    }

    children = [
      {UpdateManager, fwup_config},
      Connection,
      {Socket, config}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end
end
