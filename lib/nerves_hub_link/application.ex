defmodule NervesHubLink.Application do
  use Application

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Socket
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateManager

  def start(_type, _args) do
    connect? = Application.get_env(:nerves_hub_link, :connect, true)

    children =
      if connect? do
        config = Configurator.build()

        fwup_config = %FwupConfig{
          fwup_devpath: config.fwup_devpath,
          fwup_task: config.fwup_task,
          fwup_env: config.fwup_env,
          handle_fwup_message: &Client.handle_fwup_message/1,
          update_available: &Client.update_available/1
        }

        [
          {UpdateManager, fwup_config},
          {ArchiveManager, config},
          {Socket, config}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end
end
