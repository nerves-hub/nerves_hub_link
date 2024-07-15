defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Socket
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.PubSub
  alias NervesHubLink.UpdateManager

  def start(_type, _args) do
    config = Configurator.build()

    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_env: config.fwup_env,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }

    children = children(config, fwup_config)

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end

  defp children(%{connect: false}, _fwup_config), do: [PubSub]

  defp children(config, fwup_config) do
    [
      PubSub,
      {UpdateManager, fwup_config},
      {ArchiveManager, config},
      {Socket, config}
    ]
  end
end
