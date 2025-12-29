defmodule NervesHubLink.MixProject do
  use Mix.Project

  @version "2.9.0"
  @description "Manage your Nerves fleet by connecting it to NervesHub"
  @source_url "https://github.com/nerves-hub/nerves_hub_link"

  def project do
    [
      app: :nerves_hub_link,
      deps: deps(),
      description: @description,
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      version: @version
    ]
  end

  def application do
    [
      env: [
        host: nil,
        fwup_public_keys: []
      ],
      extra_applications: [:logger, :iex, :inets, :sasl, :os_mon],
      mod: {NervesHubLink.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        docs: :docs,
        "hex.publish": :docs
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]

  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :error_handling, :underspecs, :unmatched_returns],
      plt_file: {:no_warn, "priv/plts/project.plt"},
      plt_add_apps: [:ex_unit]
    ]
  end

  defp docs do
    [
      extras: [
        "README.md",
        "guides/configuration.md": [title: "Configuration"],
        "guides/extensions.md": [title: "Extensions"],
        "guides/debugging.md": [title: "Debugging"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      groups_for_modules: [
        Client: [
          NervesHubLink.Client,
          NervesHubLink.Client.Default
        ],
        Configuration: [
          NervesHubLink.Configurator,
          NervesHubLink.Configurator.Config,
          NervesHubLink.Configurator.LocalCertKey,
          NervesHubLink.Configurator.NervesKey,
          NervesHubLink.Configurator.SharedSecret,
          NervesHubLink.Configurator.TPM,
          NervesHubLink.FwupConfig
        ],
        Extensions: [
          NervesHubLink.Extensions,
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Geo.DefaultResolver,
          NervesHubLink.Extensions.Geo.Resolver,
          NervesHubLink.Extensions.Health,
          NervesHubLink.Extensions.Health.DefaultReport,
          NervesHubLink.Extensions.Health.DeviceStatus,
          NervesHubLink.Extensions.Health.MetricSet,
          NervesHubLink.Extensions.Health.MetricSet.CPU,
          NervesHubLink.Extensions.Health.MetricSet.Disk,
          NervesHubLink.Extensions.Health.MetricSet.Memory,
          NervesHubLink.Extensions.Health.MetricSet.NetworkTraffic,
          NervesHubLink.Extensions.Health.Report,
          NervesHubLink.Extensions.LocalShell
        ],
        "Downloads and Updates": [
          NervesHubLink.UpdateManager,
          NervesHubLink.UpdateManager.State,
          NervesHubLink.UpdateManager.Updater,
          NervesHubLink.UpdateManager.CachingUpdater,
          NervesHubLink.UpdateManager.StreamingUpdater,
          NervesHubLink.ArchiveManager,
          NervesHubLink.Downloader,
          NervesHubLink.Downloader.RetryConfig,
          NervesHubLink.Downloader.TimeoutCalculation
        ],
        "NervesHub Messages": [
          NervesHubLink.Message.ArchiveInfo,
          NervesHubLink.Message.FirmwareMetadata,
          NervesHubLink.Message.UpdateInfo
        ],
        Utilities: [
          NervesHubLink.Alarms,
          NervesHubLink.Backoff,
          NervesHubLink.Certificate
        ]
      ]
    ]
  end

  defp package do
    [
      files: [
        "CHANGELOG.md",
        "lib",
        "LICENSES/*",
        "mix.exs",
        "NOTICE",
        "README.md",
        "REUSE.toml"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "REUSE Compliance" =>
          "https://api.reuse.software/info/github.com/nerves-hub/nerves_hub_link"
      }
    ]
  end

  defp deps do
    [
      {:alarmist, "~> 0.3", optional: true},
      {:castore, "~> 0.1 or ~> 1.0", optional: true},
      {:credo, "~> 1.2", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: :test},
      {:ex_doc, "~> 0.18", only: :docs, runtime: false},
      {:expty, "~> 0.2.1", optional: true},
      {:extty, "~> 0.4.1"},
      {:fwup, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:mint, "~> 1.2"},
      {:mox, "~> 1.0", only: :test},
      {:nerves_key, "~> 1.0 or ~> 0.5", optional: true},
      {:vintage_net, "~> 0.13", optional: true},
      {:nerves_runtime, "~> 0.8"},
      {:nerves_time, "~> 0.4"},
      {:nimble_options, "~> 1.0"},
      {:plug_crypto, "~> 2.0"},
      {:bandit, "~> 1.10.0", only: :test},
      {:slipstream, "~> 1.0 or ~> 0.8"},
      {:tpm, "~> 0.2.0", optional: true},
      {:whenwhere, "~> 0.1.2"},
      {:x509, "~> 0.5"}
    ]
  end
end
