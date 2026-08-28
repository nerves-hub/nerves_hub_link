# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2026 Eliel A. Gordon
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Supervisor do
  @moduledoc """
  Supervisor for the NervesHubLink connection processes.

  By default `:nerves_hub_link` starts this supervisor automatically as part
  of its application (see the "Supervision" section of the configuration
  guide). If you'd rather own the lifecycle yourself, set:

      config :nerves_hub_link, start: :manual

  and add this supervisor to your own supervision tree, optionally passing a
  fully built `NervesHubLink.Configurator.Config`:

      children = [
        {NervesHubLink.Supervisor, config: MyApp.build_nh_config()}
      ]

  When no `:config` is provided, the configuration is built from the
  application environment via `NervesHubLink.Configurator.build/0`, which is
  the same behaviour used when the supervisor is auto-started.

  ## Options

    * `:config` - a `NervesHubLink.Configurator.Config` struct to use directly.
      Defaults to the result of `NervesHubLink.Configurator.build/0`.
    * `:name` - the name to register the supervisor under. Defaults to
      `NervesHubLink.Supervisor`.
  """

  use Supervisor

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Configurator
  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.Logging
  alias NervesHubLink.ExtensionsSupervisor
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Socket
  alias NervesHubLink.SupportScriptsManager
  alias NervesHubLink.UpdateManager

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    # An explicit config wins; otherwise fall back to building it from the
    # application environment so the auto-started path is unchanged.
    config = Keyword.get_lazy(opts, :config, &Configurator.build/0)

    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_extra_options: config.fwup_extra_options,
      fwup_env: config.fwup_env
    }

    children =
      [
        {DynamicSupervisor, name: ExtensionsSupervisor},
        Extensions,
        # Before the socket, and whether or not NervesHub ever attaches
        # logging: the lines a device writes while booting are the ones worth
        # having, and by the time an extension is attached they are gone.
        log_collector(),
        {UpdateManager, {fwup_config, config.updater}},
        {ArchiveManager, config},
        {Socket, config},
        {Task.Supervisor, name: SupportScriptsTaskSupervisor},
        SupportScriptsManager
      ]
      |> List.flatten()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Only for devices that offer the version of logging that collects. 0.0.1
  # installs its own handler when it attaches and has nothing to collect into.
  defp log_collector() do
    if Logging.Batched in Extensions.configured_modules() do
      [{Logging.Collector, level: Logging.Config.level(), max_lines: Logging.Config.max_lines()}]
    else
      []
    end
  end
end
