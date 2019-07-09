defmodule NervesHubDevice.MixProject do
  use Mix.Project

  Application.put_env(
    :nerves_hub_device,
    :nerves_provisioning,
    Path.expand("priv/provisioning.conf")
  )

  def project do
    [
      app: :nerves_hub_device,
      deps: deps(),
      description: description(),
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
      version: "0.7.5"
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
      mod: {NervesHubDevice.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]

  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "The NervesHub device application"
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/smartrent/nerves_hub_device"}
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.0.0-rc.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.18", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: :test},
      {:fwup, "~> 0.3.0"},
      {:jason, "~> 1.0"},
      {:mix_test_watch, "~> 0.8", only: :dev, runtime: false},
      {:mox, "~> 0.4", only: :test},
      {:nerves_hub_cli, "~> 0.8", runtime: false},
      {:nerves_key, "~> 0.5"},
      {:nerves_runtime, "~> 0.8"},
      {:phoenix_client, "~> 0.7"},
      {:websocket_client, "~> 1.3"},
      {:x509, "~> 0.5"}
    ]
  end
end
