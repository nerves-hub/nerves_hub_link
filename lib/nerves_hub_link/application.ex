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

    maybe_create_firmware_reverted_alarm()

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
          Extensions,
          {UpdateManager, fwup_config},
          {ArchiveManager, config},
          {Socket, config}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end

  def maybe_create_firmware_reverted_alarm() do
    if Nerves.Runtime.KV.get("nerves_fw_reverted") == "true" do
      :alarm_handler.set_alarm({Nerves.FirmwareReverted, []})
    end

    :ok
  end
end
