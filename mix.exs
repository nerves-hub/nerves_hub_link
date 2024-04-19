defmodule NervesHubLink.MixProject do
  use Mix.Project

  @version "2.2.1"
  @description "Manage your Nerves fleet by connecting it to NervesHub"
  @source_url "https://github.com/nerves-hub/nerves_hub_link"

  Application.put_env(
    :nerves_hub_link,
    :nerves_provisioning,
    Path.expand("provisioning.conf")
  )

  def project do
    [
      app: :nerves_hub_link,
      deps: deps(),
      description: @description,
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        docs: :docs,
        "hex.publish": :docs
      ],
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      version: @version
    ]
  end

  def application do
    [
      env: [
        device_api_host: nil,
        device_api_port: 443,
        device_api_sni: nil,
        fwup_public_keys: []
      ],
      extra_applications: [:logger, :iex, :inets, :sasl],
      mod: {NervesHubLink.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]

  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :error_handling, :underspecs, :unmatched_returns],
      plt_add_apps: [:atecc508a, :nerves_key, :nerves_key_pkcs11],
      list_unused_filters: true
    ]
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: [
        "lib",
        "CHANGELOG.md",
        "LICENSE",
        "mix.exs",
        "README.md",
        "provisioning.conf"
      ]
    ]
  end

  defp deps do
    [
      {:castore, "~> 0.1 or ~> 1.0", optional: true},
      {:credo, "~> 1.2", only: :test, runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: :test},
      {:ex_doc, "~> 0.18", only: :docs, runtime: false},
      {:extty, "~> 0.2"},
      {:fwup, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:mint, "~> 1.2"},
      {:mox, "~> 1.0", only: :test},
      {:nerves_key, "~> 1.0 or ~> 0.5", optional: true},
      {:nerves_runtime, "~> 0.8"},
      {:nerves_time, "~> 0.4"},
      {:plug_crypto, "~> 2.0"},
      {:plug_cowboy, "~> 2.0", only: :test},
      {:slipstream, "~> 1.0 or ~> 0.8"},
      {:x509, "~> 0.5"}
    ]
  end
end
