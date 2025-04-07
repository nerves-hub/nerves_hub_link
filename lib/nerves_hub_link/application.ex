# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Application do
  @moduledoc false
  use Application

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Extensions
  alias NervesHubLink.ExtensionsSupervisor
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Socket
  alias NervesHubLink.UpdateManager

  @impl Application
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
          {DynamicSupervisor, name: ExtensionsSupervisor},
          {Task.Supervisor, name: NervesHubLink.TaskSupervisor},
          Extensions,
          {UpdateManager, fwup_config},
          {ArchiveManager, config},
          {Socket, config}
        ]
      else
        [
          {Task.Supervisor, name: NervesHubLink.TaskSupervisor}
        ]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end
end
