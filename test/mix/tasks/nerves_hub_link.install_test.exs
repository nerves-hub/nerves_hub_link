# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.NervesHubLink.InstallTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @target_exs """
  import Config

  config :nerves, :erlinit, update_clock: true
  """

  @host_exs """
  import Config

  config :nerves_runtime, target: "host"
  """

  defp nerves_project(files \\ %{}) do
    test_project(
      files:
        Map.merge(%{"config/target.exs" => @target_exs, "config/host.exs" => @host_exs}, files)
    )
  end

  defp install(igniter, argv \\ []) do
    Igniter.compose_task(igniter, "nerves_hub_link.install", argv)
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp config(igniter, path) do
    path
    |> Config.Reader.eval!(content(igniter, path), env: :dev)
    |> Keyword.fetch!(:nerves_hub_link)
  end

  describe "defaults in a Nerves project" do
    test "configures shared secret auth in config/target.exs from the environment" do
      igniter = nerves_project() |> install()

      assert igniter.issues == []

      assert_has_patch(igniter, "config/target.exs", """
      + |config :nerves_hub_link,
      + |  host: "devices.nervescloud.com",
      + |  shared_secret: [
      + |    product_key: System.get_env("NERVES_HUB_PRODUCT_KEY"),
      + |    product_secret: System.get_env("NERVES_HUB_PRODUCT_SECRET")
      + |  ]
      """)

      refute content(igniter, "config/target.exs") =~ "remote_iex"
    end

    test "does not connect on the host" do
      nerves_project()
      |> install()
      |> assert_has_patch("config/host.exs", """
      + |config :nerves_hub_link, connect: false
      """)
    end

    test "leaves config/config.exs and mix.exs alone" do
      nerves_project(%{"config/config.exs" => "import Config\n"})
      |> install()
      |> assert_unchanged(["config/config.exs", "mix.exs"])
    end

    test "the generated config evaluates and takes the values from the environment" do
      # Runs in the test process only: `Config.Reader` evaluates the generated
      # file and nothing is put in the application environment.
      igniter = nerves_project() |> install() |> apply_igniter!()

      config = config(igniter, "config/target.exs")

      assert config[:host] == "devices.nervescloud.com"

      assert config[:shared_secret] == [
               product_key: System.get_env("NERVES_HUB_PRODUCT_KEY"),
               product_secret: System.get_env("NERVES_HUB_PRODUCT_SECRET")
             ]

      assert config(igniter, "config/host.exs") == [connect: false]
    end

    test "tells the user what is left to do, without a missing-target notice" do
      igniter = nerves_project() |> install()

      igniter
      |> assert_has_notice(&(&1 =~ "no `--nerves-hub-host` was given"))
      |> assert_has_notice(
        &(&1 =~ "export NERVES_HUB_PRODUCT_KEY=" and &1 =~ "export NERVES_HUB_PRODUCT_SECRET=" and
            &1 =~ "Create a Product" and &1 =~ "No secret was written")
      )
      |> assert_has_notice(&(&1 =~ "mix nerves_hub.key create" and &1 =~ "serial number"))
      # Verified on a device: without the secret, the application doesn't start
      |> assert_has_notice(&(&1 =~ "NervesHubLink then fails to start on the device"))

      refute Enum.any?(igniter.notices, &(&1 =~ "no `config/target.exs` was found"))
    end

    test "is idempotent" do
      nerves_project()
      |> install()
      |> apply_igniter!()
      |> install()
      |> assert_unchanged()
    end
  end

  describe "a project that is not a Nerves project" do
    test "falls back to config/config.exs with a notice" do
      igniter = test_project() |> install()

      igniter
      |> assert_creates("config/config.exs")
      |> assert_has_notice(&(&1 =~ "no `config/target.exs` was found"))
      |> assert_has_notice(&(&1 =~ "export NERVES_HUB_PRODUCT_KEY="))

      config = igniter |> apply_igniter!() |> config("config/config.exs")

      assert config[:host] == "devices.nervescloud.com"
      assert Keyword.keys(config[:shared_secret]) == [:product_key, :product_secret]
      refute Keyword.has_key?(config, :connect)
    end

    test "is idempotent" do
      test_project()
      |> install()
      |> apply_igniter!()
      |> install()
      |> assert_unchanged()
    end

    test "only config/target.exs is needed to count as a Nerves project" do
      igniter = test_project(files: %{"config/target.exs" => @target_exs}) |> install()

      assert_has_patch(igniter, "config/target.exs", """
      + |  host: "devices.nervescloud.com",
      """)

      refute Igniter.exists?(igniter, "config/host.exs")
    end
  end

  describe "existing configuration" do
    test "is preserved" do
      target_exs = """
      import Config

      config :nerves_hub_link,
        host: "devices.mine.example",
        shared_secret: [product_key: System.fetch_env!("MY_KEY"), product_secret: "from-a-vault"]
      """

      host_exs = """
      import Config

      config :nerves_hub_link, connect: true
      """

      nerves_project(%{"config/target.exs" => target_exs, "config/host.exs" => host_exs})
      |> install(["--nerves-hub-host", "other.example", "--nerves-hub-remote-iex"])
      |> assert_unchanged("config/host.exs")
      |> assert_has_patch("config/target.exs", """
      + |  remote_iex: true
      """)
      |> then(fn igniter ->
        content = content(igniter, "config/target.exs")

        assert content =~ ~s|host: "devices.mine.example"|
        assert content =~ ~s|System.fetch_env!("MY_KEY")|
        assert content =~ ~s|product_secret: "from-a-vault"|
        refute content =~ "other.example"
        refute content =~ "NERVES_HUB_PRODUCT_KEY"
      end)
    end

    test "a configured configurator is not replaced" do
      target_exs = """
      import Config

      config :nerves_hub_link, host: "devices.mine.example", configurator: MyApp.Configurator
      """

      igniter =
        nerves_project(%{"config/target.exs" => target_exs})
        |> install(["--nerves-hub-auth", "local-cert"])

      assert_unchanged(igniter, "config/target.exs")
    end
  end

  describe "--nerves-hub-host" do
    test "sets the host and drops the default host notice" do
      igniter = nerves_project() |> install(["--nerves-hub-host", "devices.example.com:4001"])

      assert_has_patch(igniter, "config/target.exs", """
      + |  host: "devices.example.com:4001",
      """)

      refute content(igniter, "config/target.exs") =~ "devices.nervescloud.com"
      refute Enum.any?(igniter.notices, &(&1 =~ "no `--nerves-hub-host` was given"))
    end
  end

  describe "--nerves-hub-remote-iex" do
    test "enables the remote console" do
      igniter = nerves_project() |> install(["--nerves-hub-remote-iex"]) |> apply_igniter!()

      assert config(igniter, "config/target.exs")[:remote_iex] == true
    end

    test "--no-nerves-hub-remote-iex writes nothing" do
      igniter = nerves_project() |> install(["--no-nerves-hub-remote-iex"])

      refute content(igniter, "config/target.exs") =~ "remote_iex"
    end
  end

  describe "--nerves-hub-auth" do
    test "shared-secret is the default" do
      explicit = nerves_project() |> install(["--nerves-hub-auth", "shared-secret"])
      default = nerves_project() |> install()

      assert content(explicit, "config/target.exs") == content(default, "config/target.exs")
    end

    test "is asked for when it isn't passed and there's a terminal" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      send(self(), {:mix_shell_input, :prompt, "3"})

      igniter =
        nerves_project()
        |> Igniter.assign(:nerves_hub_link_interactive?, true)
        |> install()

      assert_received {:mix_shell, :prompt, [prompt]}
      assert prompt =~ "How should devices authenticate with NervesHub?"
      assert prompt =~ "shared-secret"
      assert prompt =~ "(Default)"

      assert config(igniter, "config/target.exs")[:configurator] ==
               NervesHubLink.Configurator.LocalCertKey
    end

    test "pressing enter at the prompt picks shared-secret" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      send(self(), {:mix_shell_input, :prompt, ""})

      asked =
        nerves_project()
        |> Igniter.assign(:nerves_hub_link_interactive?, true)
        |> install()

      explicit = nerves_project() |> install(["--nerves-hub-auth", "shared-secret"])
      assert content(asked, "config/target.exs") == content(explicit, "config/target.exs")
    end

    test "isn't asked for when it's passed, with --yes or when already set up" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      nerves_project()
      |> Igniter.assign(:nerves_hub_link_interactive?, true)
      |> install(["--nerves-hub-auth", "tpm"])

      with_yes =
        nerves_project()
        |> Igniter.assign(:nerves_hub_link_interactive?, true)
        |> install(["--yes"])

      assert content(with_yes, "config/target.exs") =~ "shared_secret"

      nerves_project()
      |> install(["--nerves-hub-auth", "local-cert"])
      |> apply_igniter!()
      |> Igniter.assign(:nerves_hub_link_interactive?, true)
      |> install()
      |> assert_unchanged()

      refute_received {:mix_shell, :prompt, _}
    end

    test "nerves-key adds the dependency and only configures the host" do
      igniter = nerves_project() |> install(["--nerves-hub-auth", "nerves-key"])

      igniter
      |> assert_has_patch("mix.exs", """
      + |      {:nerves_key, "~> 1.2"}
      """)
      |> assert_has_patch("config/target.exs", """
      + |config :nerves_hub_link, host: "devices.nervescloud.com"
      """)
      |> assert_has_notice(&(&1 =~ "NervesKey" and &1 =~ "signer CA certificate"))

      refute content(igniter, "config/target.exs") =~ "shared_secret"
      refute Enum.any?(igniter.notices, &(&1 =~ "NERVES_HUB_PRODUCT_SECRET"))
    end

    test "nerves-key keeps a nerves_key dependency that is already there" do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", deps: deps()]
        end

        defp deps do
          [{:nerves_key, "~> 1.0"}]
        end
      end
      """

      nerves_project(%{"mix.exs" => mix_exs})
      |> install(["--nerves-hub-auth", "nerves-key"])
      |> assert_unchanged("mix.exs")
    end

    test "tpm adds the dependency and only configures the host" do
      igniter = nerves_project() |> install(["--nerves-hub-auth", "tpm"])

      igniter
      |> assert_has_patch("mix.exs", """
      + |      {:tpm, "~> 0.2.0"}
      """)
      |> assert_has_notice(&(&1 =~ "TPM" and &1 =~ "signer CA certificate"))

      refute content(igniter, "config/target.exs") =~ "shared_secret"
    end

    test "local-cert sets the configurator and generates no key material" do
      igniter = nerves_project() |> install(["--nerves-hub-auth", "local-cert"])

      igniter
      |> assert_has_patch("config/target.exs", """
      + |config :nerves_hub_link,
      + |  host: "devices.nervescloud.com",
      + |  configurator: NervesHubLink.Configurator.LocalCertKey
      """)
      |> assert_has_notice(&(&1 =~ "/data/nerves_hub/cert.pem" and &1 =~ "No certificate or key"))

      refute content(igniter, "config/target.exs") =~ "shared_secret"
      assert_unchanged(igniter, "mix.exs")
    end

    for auth <- ["nerves-key", "tpm", "local-cert"] do
      test "#{auth} is idempotent" do
        argv = ["--nerves-hub-auth", unquote(auth)]

        nerves_project()
        |> install(argv)
        |> apply_igniter!()
        |> install(argv)
        |> assert_unchanged()
      end
    end

    test "an unknown method is an issue and changes nothing" do
      igniter = nerves_project() |> install(["--nerves-hub-auth", "password"])

      assert [issue] = igniter.issues
      assert issue =~ "Unknown --nerves-hub-auth \"password\""
      assert issue =~ "shared-secret, nerves-key, tpm, local-cert"
      assert_unchanged(igniter)
    end
  end

  test "no secret-looking literal is ever generated" do
    for auth <- ["shared-secret", "nerves-key", "tpm", "local-cert"] do
      igniter = nerves_project() |> install(["--nerves-hub-auth", auth]) |> apply_igniter!()

      for path <- ["config/target.exs", "config/host.exs"] do
        content = content(igniter, path)

        refute content =~ "nhp_"
        refute content =~ ~r/product_(key|secret): "/
      end
    end
  end
end
