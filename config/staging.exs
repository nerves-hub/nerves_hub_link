import Config

config :nerves_hub_cli,
  home_dir: Path.expand("../nerves-hub", __DIR__)

# API HTTP connection.
config :nerves_hub_user_api,
  host: "api.staging.nerves-hub.org",
  port: 443

# Device HTTP connection.
config :nerves_hub_link,
  device_api_host: "device.staging.nerves-hub.org",
  device_api_port: 443

config :nerves_hub_link,
  ssl: [server_name_indication: ~c"device.staging.nerves-hub.org"],
  reconnect_interval: 1_000

# nerves_runtime needs to disable
# and mock out some parts.

cert =
  if File.exists?("./nerves-hub/test-cert.pem"),
    do: File.read!("./nerves-hub/test-cert.pem")

key =
  if File.exists?("./nerves-hub/test-key.pem"),
    do: File.read!("./nerves-hub/test-key.pem")
