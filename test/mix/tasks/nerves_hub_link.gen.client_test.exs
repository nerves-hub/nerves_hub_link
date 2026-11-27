# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.NervesHubLink.Gen.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Igniter.Test

  alias Nerves.Runtime.KV
  alias NervesHubLink.Client.Default
  alias NervesHubLink.Message.ArchiveInfo
  alias NervesHubLink.Message.FirmwareMetadata
  alias NervesHubLink.Message.UpdateInfo

  @target_exs """
  import Config

  config :nerves, :erlinit, update_clock: true
  """

  @host_exs """
  import Config

  config :nerves_runtime, target: "host"
  """

  @client_path "lib/test/nerves_hub_client.ex"

  defp nerves_project(files \\ %{}) do
    test_project(
      files:
        Map.merge(%{"config/target.exs" => @target_exs, "config/host.exs" => @host_exs}, files)
    )
  end

  # A Nerves project that `mix nerves_hub_link.install` has been run in
  defp installed_project(files \\ %{}) do
    nerves_project(files)
    |> Igniter.compose_task("nerves_hub_link.install", [])
    |> apply_igniter!()
  end

  defp gen_client(igniter, argv \\ []) do
    Igniter.compose_task(igniter, "nerves_hub_link.gen.client", argv)
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp config(igniter, path) do
    path
    |> Config.Reader.eval!(content(igniter, path), env: :dev)
    |> Keyword.fetch!(:nerves_hub_link)
  end

  # Compiles the generated source against this repo's `NervesHubLink.Client`
  # and fails on any warning.
  defp compile!(source, module) do
    {compiled, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source, "generated_client.ex") end)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    assert diagnostics == []
    assert [{^module, _bytecode}] = compiled

    module
  end

  defp mix_exs(nerves_hub_link_dep) do
    """
    defmodule Test.MixProject do
      use Mix.Project

      @all_targets [:rpi4, :rpi5]

      def project do
        [app: :test, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [
          #{nerves_hub_link_dep}
        ]
      end
    end
    """
  end

  describe "a Nerves project after nerves_hub_link.install" do
    test "generates the client module" do
      igniter = installed_project() |> gen_client()

      assert igniter.issues == []
      assert_creates(igniter, @client_path)

      source = content(igniter, @client_path)

      assert source =~ "defmodule Test.NervesHubClient do"
      assert source =~ "use NervesHubLink.Client"
      refute source =~ "Code.ensure_loaded?"

      for callback <- [
            "update_available(update_info)",
            "archive_available(archive_info)",
            "archive_ready(archive_info, file_path)",
            "handle_fwup_message(fwup_message)",
            "handle_error(error)",
            "identify()",
            "reconnect_backoff()"
          ] do
        assert source =~ "@impl NervesHubLink.Client\n  def #{callback} do"
      end
    end

    test "points the device config at it, next to what the installer wrote" do
      igniter = installed_project() |> gen_client()

      assert_has_patch(igniter, "config/target.exs", """
      + |  client: Test.NervesHubClient
      """)

      assert_unchanged(igniter, ["config/host.exs", "mix.exs"])

      config = igniter |> apply_igniter!() |> config("config/target.exs")

      assert config[:client] == Test.NervesHubClient
      assert config[:host] == "devices.nervescloud.com"
    end

    test "says what was generated, without a missing-target notice" do
      igniter = installed_project() |> gen_client()

      assert_has_notice(
        igniter,
        &(&1 =~ "generated `Test.NervesHubClient` in `#{@client_path}`" and
            &1 =~ "update_available/1")
      )

      refute Enum.any?(igniter.notices, &(&1 =~ "no `config/target.exs` was found"))
      refute Enum.any?(igniter.notices, &(&1 =~ "Code.ensure_loaded?"))
    end

    test "is idempotent" do
      igniter =
        installed_project()
        |> gen_client()
        |> apply_igniter!()
        |> gen_client()

      assert_unchanged(igniter)
      assert igniter.issues == []
      refute Enum.any?(igniter.notices, &(&1 =~ "already sets a `client`"))
    end

    test "works without the installer having been run" do
      nerves_project()
      |> gen_client()
      |> assert_creates(@client_path)
      |> assert_has_patch("config/target.exs", """
      + |config :nerves_hub_link, client: Test.NervesHubClient
      """)
    end
  end

  describe "a project that is not a Nerves project" do
    test "falls back to config/config.exs with a notice" do
      igniter = test_project() |> gen_client()

      assert igniter.issues == []
      assert_creates(igniter, @client_path)
      assert_has_notice(igniter, &(&1 =~ "no `config/target.exs` was found"))

      config = igniter |> apply_igniter!() |> config("config/config.exs")

      assert config == [client: Test.NervesHubClient]
    end

    test "is idempotent" do
      test_project()
      |> gen_client()
      |> apply_igniter!()
      |> gen_client()
      |> assert_unchanged()
    end
  end

  describe "the module name" do
    test "can be given as an argument" do
      igniter = installed_project() |> gen_client(["MyDevice.Hub.Client"])

      assert igniter.issues == []
      assert_creates(igniter, "lib/my_device/hub/client.ex")
      assert content(igniter, "lib/my_device/hub/client.ex") =~ "defmodule MyDevice.Hub.Client do"

      assert_has_patch(igniter, "config/target.exs", """
      + |  client: MyDevice.Hub.Client
      """)

      refute Enum.any?(igniter.rewrite, &(&1.path == @client_path))
    end

    test "has to be a module name" do
      igniter = installed_project() |> gen_client(["not_a_module"])

      assert [issue] = igniter.issues
      assert issue =~ ~s("not_a_module" is not a valid module name)
      assert_unchanged(igniter, "config/target.exs")
    end
  end

  describe "an existing client setting" do
    @configured_target_exs """
    import Config

    config :nerves_hub_link, host: "devices.example.com", client: Test.MyOwnClient
    """

    test "is kept, with a notice" do
      igniter =
        nerves_project(%{"config/target.exs" => @configured_target_exs})
        |> gen_client()

      assert_unchanged(igniter, "config/target.exs")
      assert_creates(igniter, @client_path)

      assert_has_notice(
        igniter,
        &(&1 =~ "`config/target.exs` already sets a `client`" and
            &1 =~ "config :nerves_hub_link, client: Test.NervesHubClient")
      )
    end

    test "in config/config.exs is kept too, and nothing is added to config/target.exs" do
      config_exs = """
      import Config

      config :nerves_hub_link, :client, Test.MyOwnClient
      """

      igniter =
        nerves_project(%{"config/config.exs" => config_exs})
        |> gen_client()

      assert_unchanged(igniter, ["config/config.exs", "config/target.exs"])
      assert_has_notice(igniter, &(&1 =~ "`config/config.exs` already sets a `client`"))
    end

    test "for a module whose name starts the same is still noticed" do
      target_exs = """
      import Config

      config :nerves_hub_link, client: Test.NervesHubClient.Other
      """

      nerves_project(%{"config/target.exs" => target_exs})
      |> gen_client()
      |> assert_unchanged("config/target.exs")
      |> assert_has_notice(&(&1 =~ "already sets a `client`"))
    end
  end

  describe "an existing module" do
    @existing """
    defmodule Test.NervesHubClient do
      use NervesHubLink.Client

      @impl NervesHubLink.Client
      def update_available(_update_info), do: {:reschedule, 60_000}
    end
    """

    test "is not overwritten, and is still configured" do
      igniter =
        installed_project(%{@client_path => @existing})
        |> gen_client()

      assert igniter.issues == []
      assert_unchanged(igniter, @client_path)
      assert_has_notice(igniter, &(&1 =~ "`Test.NervesHubClient` already exists"))

      assert_has_patch(igniter, "config/target.exs", """
      + |  client: Test.NervesHubClient
      """)
    end

    test "is not overwritten when it lives in another file" do
      igniter =
        installed_project(%{"lib/somewhere/else.ex" => @existing})
        |> gen_client()

      assert_unchanged(igniter, "lib/somewhere/else.ex")
      assert_has_notice(igniter, &(&1 =~ "`Test.NervesHubClient` already exists"))
      refute Enum.any?(igniter.rewrite, &(&1.path == @client_path))
    end

    test "a file with another module where the client would go is not overwritten" do
      other = """
      defmodule Test.SomethingElse do
      end
      """

      igniter =
        installed_project(%{@client_path => other})
        |> gen_client()

      assert igniter.issues == []
      assert_unchanged(igniter, @client_path)
      assert_has_notice(igniter, &(&1 =~ "`#{@client_path}` already exists"))
    end
  end

  describe "nerves_hub_link as a dependency for some targets only" do
    test "guards the module so that host builds without NervesHubLink compile" do
      igniter =
        nerves_project(%{
          "mix.exs" => mix_exs(~s({:nerves_hub_link, "~> 2.0", targets: @all_targets}))
        })
        |> gen_client()

      assert igniter.issues == []

      source = content(igniter, @client_path)

      assert source =~ "if Code.ensure_loaded?(NervesHubLink.Client) do\n  defmodule Test."
      assert_has_notice(igniter, &(&1 =~ "if Code.ensure_loaded?(NervesHubLink.Client)"))

      # Formatted, as the project's `mix format --check-formatted` would want
      assert source == source |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")

      module = compile!(source, Test.NervesHubClient)

      assert module.__info__(:functions) == Default.__info__(:functions)
    end

    test "does not guard it when the dependency is there for every target" do
      igniter =
        nerves_project(%{"mix.exs" => mix_exs(~s({:nerves_hub_link, "~> 2.0"}))})
        |> gen_client()

      refute content(igniter, @client_path) =~ "Code.ensure_loaded?"
    end
  end

  describe "the generated module" do
    setup do
      source = installed_project() |> gen_client() |> content(@client_path)

      %{source: source, client: compile!(source, Test.NervesHubClient)}
    end

    test "is formatted", %{source: source} do
      assert source == source |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
    end

    test "implements the behaviour with the same functions as the default client", %{
      client: client
    } do
      assert NervesHubLink.Client in client.module_info(:attributes)[:behaviour]
      assert client.__info__(:functions) == Default.__info__(:functions)

      # The optional callbacks are left for NervesHubLink to handle
      for callback <- [
            :connected,
            :reboot,
            :firmware_validated?,
            :firmware_auto_revert_detected?
          ] do
        refute function_exported?(client, callback, 0)
      end
    end

    test "decides on updates like the default client", %{client: client} do
      running = KV.get_active("nerves_fw_uuid")
      assert is_binary(running)

      for uuid <- [running, "a-different-uuid"] do
        update_info = %UpdateInfo{
          firmware_url: URI.parse("https://example.com/firmware.fw"),
          firmware_meta: %FirmwareMetadata{uuid: uuid}
        }

        {result, log} = with_log(fn -> client.update_available(update_info) end)
        {default_result, default_log} = with_log(fn -> Default.update_available(update_info) end)

        assert result == default_result
        assert log =~ "Ignoring request" == (default_log =~ "Ignoring request")
      end

      assert capture_log(fn ->
               assert client.update_available(%UpdateInfo{
                        firmware_meta: %FirmwareMetadata{uuid: running}
                      }) == :ignore
             end) =~ "Ignoring request to update to the same firmware"

      assert client.update_available(%UpdateInfo{
               firmware_meta: %FirmwareMetadata{uuid: "a-different-uuid"}
             }) == :apply
    end

    test "handles everything else like the default client", %{client: client} do
      archive_info = %ArchiveInfo{uuid: "archive-uuid", version: "1.0.0"}

      calls = [
        {:archive_available, [archive_info], :ignore},
        {:archive_ready, [archive_info, "/tmp/archive.tar.gz"], :ok},
        {:handle_fwup_message, [{:progress, 50}], :ok},
        {:handle_fwup_message, [{:ok, 0, "success"}], :ok},
        {:handle_fwup_message, [{:warning, 1, "careful"}], :ok},
        {:handle_fwup_message, [{:error, 1, "failed"}], :ok},
        {:handle_fwup_message, [:something_unknown], :ok},
        {:handle_error, [:nxdomain], :ok},
        {:identify, [], :ok},
        {:reconnect_backoff, [], nil}
      ]

      capture_log(fn ->
        for {function, args, expected} <- calls do
          result = apply(client, function, args)

          assert result == apply(Default, function, args)
          assert result == expected
        end
      end)
    end

    test "logs like the default client", %{client: client} do
      for {function, args} <- [
            {:handle_fwup_message, [{:error, 1, "failed"}]},
            {:handle_error, [:nxdomain]},
            {:identify, []}
          ] do
        log = capture_log(fn -> apply(client, function, args) end)
        default_log = capture_log(fn -> apply(Default, function, args) end)

        assert log =~ "[NervesHubLink.Client]"
        assert message(log) == message(default_log)
      end
    end

    test "uses the configured reconnect backoff like the default client", %{client: client} do
      previous = Application.get_env(:nerves_hub_link, :socket)

      on_exit(fn ->
        if previous do
          Application.put_env(:nerves_hub_link, :socket, previous)
        else
          Application.delete_env(:nerves_hub_link, :socket)
        end
      end)

      Application.put_env(:nerves_hub_link, :socket, reconnect_after_msec: [1000, 2000])

      assert client.reconnect_backoff() == [1000, 2000]
      assert client.reconnect_backoff() == Default.reconnect_backoff()
    end
  end

  # The part of a log line that follows the `[NervesHubLink.Client]` prefix
  defp message(log) do
    [_before, message] = String.split(log, "[NervesHubLink.Client]", parts: 2)
    String.trim(message)
  end
end
