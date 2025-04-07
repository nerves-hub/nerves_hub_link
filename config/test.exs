import Config

persist_dir =
  System.tmp_dir!()
  |> Path.join("nerves_hub_link_test")

File.mkdir_p!(persist_dir)

# Device HTTP connection.
config :nerves_hub_link,
  archive_public_keys: ["a key?"],
  connect: false,
  client: NervesHubLink.ClientMock,
  host: "0.0.0.0:4001",
  fwup_public_keys: ["a key"],
  # SSL values are used in a test.
  ssl: [
    cert: "ima cert!",
    key: "ima key!",
    cacerts: ["Everyone", "gets", "a", "CA"],
    server_name_indication: "waddup",
    verify: :verify_peer
  ],
  rejoin_after: 0,
  remote_iex: true,
  ensure_reboot: false,
  persist_dir: persist_dir

config :nerves_runtime,
  target: "host",
  kernel: [autoload_modules: false],
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
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
     }}

config :nerves_time, :servers, []

config :vintage_net,
  resolvconf: "/dev/null",
  persistence: VintageNet.Persistence.Null,
  bin_ip: "false"
