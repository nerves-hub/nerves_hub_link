defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Connection
  alias NervesHubLink.Socket
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateManager

  def start(_type, _args) do
    config = Configurator.build()

    fwup_config = %FwupConfig{
      fwup_public_keys: config.fwup_public_keys,
      fwup_devpath: config.fwup_devpath,
      fwup_env: config.fwup_env,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }

    children = children(config, fwup_config)

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end

  defp children(%{connect: false}, _fwup_config), do: []

  defp children(config, fwup_config) do
    [
      {UpdateManager, fwup_config},
      Connection,
      {Socket, config}
    ]
  end
end
