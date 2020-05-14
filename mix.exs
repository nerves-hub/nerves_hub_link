defmodule NervesHubLink.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_hub_link,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: [main: "readme", extras: ["README.md"]],
      elixir: "~> 1.8",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      version: "0.7.6"
    ]
  end

  def application do
    [
      env: [
        device_api_host: "device.nerves-hub.org",
        device_api_port: 443,
        device_api_sni: "device.nerves-hub.org",
        fwup_public_keys: []
      ],
      extra_applications: [:logger, :iex],
      mod: {NervesHubLink.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]

  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "The NervesHub device application"
  end

  defp dialyzer() do
    [
      # TODO: add :unmatched_returns
      flags: [:race_conditions, :error_handling, :underspecs],
      plt_add_apps: [:atecc508a, :nerves_key, :nerves_key_pkcs11],
      list_unused_filters: true
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/nerves-hub/nerves_hub_link"},
      files: [
        "lib",
        "ssl",
        "CHANGELOG.md",
        "LICENSE",
        "mix.exs",
        "README.md"
      ]
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.0.0-rc.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.18", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: :test},
      {:fwup, "~> 0.4.0"},
      {:hackney, "~> 1.10"},
      {:jason, "~> 1.0"},
      {:mix_test_watch, "~> 0.8", only: :dev, runtime: false},
      {:mox, "~> 0.4", only: :test},
      {:nerves_hub_cli, "~> 0.8", runtime: false},
      {:nerves_key, "~> 0.5", optional: true},
      {:nerves_runtime, "~> 0.8"},
      {:phoenix_client, "~> 0.7"},
      {:websocket_client, "~> 1.3"},
      {:x509, "~> 0.5"}
    ]
  end
end
