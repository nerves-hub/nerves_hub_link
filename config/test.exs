use Mix.Config

config :nerves_hub_cli,
  home_dir: Path.expand("nerves-hub")

# API HTTP connection.
config :nerves_hub_user_api,
  host: "0.0.0.0",
  port: 4002

# Device HTTP connection.
config :nerves_hub_link,
  device_api_host: "0.0.0.0",
  device_api_port: 4001,
  configurator: NervesHubLink.Configurator.Default,
  # SSL values are used in a test.
  ssl: [
    cert: "ima cert!",
    key: "ima key!",
    cacerts: ["Everyone", "gets", "a", "CA"],
    server_name_indication: "waddup",
    verify: :verify_peer
  ]

config :nerves_hub_link,
  client: NervesHubLink.ClientMock,
  rejoin_after: 0,
  remote_iex: true

config :nerves_runtime, :kernel, autoload_modules: false
config :nerves_runtime, target: "host"

config :nerves_runtime, Nerves.Runtime.KV.Mock, %{
  "nerves_fw_active" => "a",
  "a.nerves_fw_uuid" => "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8",
  "a.nerves_fw_product" => "nerves_hub",
  "a.nerves_fw_architecture" => "x86_64",
  "a.nerves_fw_version" => "0.1.0",
  "a.nerves_fw_platform" => "x86_84",
  "a.nerves_fw_misc" => "extra comments",
  "a.nerves_fw_description" => "test firmware",
  "nerves_hub_cert" => "cert",
  "nerves_hub_key" => "key",
  "nerves_fw_devpath" => "/tmp/fwup_bogus_path",
  "nerves_serial_number" => "test"
}

config :nerves_runtime, :modules, [
  {Nerves.Runtime.KV, Nerves.Runtime.KV.Mock}
]

config :phoenix, json_library: Jason
