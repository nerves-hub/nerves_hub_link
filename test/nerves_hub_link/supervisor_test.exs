# SPDX-FileCopyrightText: 2026 Eliel A. Gordon
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SupervisorTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateManager.StreamingUpdater

  # `init/1` is a pure function that returns the normalized child specs, so we
  # can assert on the wiring without booting the (networked) child processes.
  defp child_start_modules({:ok, {_flags, specs}}) do
    Enum.map(specs, fn %{start: {mod, _fun, _args}} -> mod end)
  end

  defp child_spec_for({:ok, {_flags, specs}}, mod) do
    Enum.find(specs, fn %{start: {m, _fun, _args}} -> m == mod end)
  end

  test "init/1 wires up the expected children in order" do
    result = NervesHubLink.Supervisor.init(config: %Config{})

    assert {:ok, {%{strategy: :one_for_one}, _specs}} = result

    assert child_start_modules(result) == [
             DynamicSupervisor,
             NervesHubLink.Extensions,
             NervesHubLink.UpdateManager,
             NervesHubLink.ArchiveManager,
             NervesHubLink.Socket,
             Task.Supervisor,
             NervesHubLink.SupportScriptsManager
           ]
  end

  test "init/1 threads the given config into the update manager" do
    config = %Config{
      fwup_devpath: "/dev/loop0",
      fwup_task: "upgrade",
      fwup_extra_options: ["--unsafe"],
      fwup_env: [{"KEY", "VALUE"}],
      updater: StreamingUpdater
    }

    result = NervesHubLink.Supervisor.init(config: config)

    %{start: {_mod, _fun, [{fwup_config, updater} | _]}} =
      child_spec_for(result, NervesHubLink.UpdateManager)

    assert fwup_config == %FwupConfig{
             fwup_devpath: "/dev/loop0",
             fwup_task: "upgrade",
             fwup_extra_options: ["--unsafe"],
             fwup_env: [{"KEY", "VALUE"}]
           }

    assert updater == StreamingUpdater
  end

  test "init/1 falls back to Configurator.build/0 when no config is given" do
    # No :config option means the old application-environment path is used.
    assert {:ok, {%{strategy: :one_for_one}, specs}} = NervesHubLink.Supervisor.init([])
    assert length(specs) == 7
  end

  test "the application does not auto-start children when connect: false" do
    # The test environment sets `connect: false`, so the application-level
    # supervisor should come up with no children.
    assert is_pid(Process.whereis(NervesHubLink.ApplicationSupervisor))
    assert Supervisor.which_children(NervesHubLink.ApplicationSupervisor) == []
  end
end
