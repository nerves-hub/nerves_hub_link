defmodule NervesHubLink.Configurator do
  alias __MODULE__.{Config, Default}
  require Logger

  @device_api_version "1.0.0"
  @console_version "1.0.0"

  defmodule Config do
    defstruct device_api_host: "device.nerves-hub.org",
              device_api_port: 443,
              device_api_sni: "device.nerves-hub.org",
              fwup_public_keys: [],
              fwup_devpath: "/dev/mmcblk0",
              nerves_key: [],
              params: %{},
              remote_iex: false,
              socket: [],
              ssl: []

    @type t() :: %__MODULE__{
            device_api_host: String.t(),
            device_api_port: String.t(),
            device_api_sni: charlist(),
            fwup_public_keys: [binary()],
            fwup_devpath: Path.t(),
            nerves_key: any(),
            params: map(),
            remote_iex: boolean,
            socket: any(),
            ssl: [:ssl.tls_client_option()]
          }
  end

  @callback build(%Config{}) :: Config.t()

  @fwup_devpath "nerves_fw_devpath"

  @spec build :: Config.t()
  def build() do
    Application.get_env(:nerves_hub_link, :configurator, fetch_default())
    |> do_build()
    |> add_socket_opts()
    |> add_fwup_public_keys()
  end

  defp add_socket_opts(config) do
    # PhoenixClient requires these SSL options be passed as
    # [transport_opts: [socket_opts: ssl]]. So for convenience,
    # we'll bundle it all here as expected without overriding
    # any other items that may have been provided in :socket or
    # :transport_opts keys previously.
    transport_opts = config.socket[:transport_opts] || []

    transport_opts = Keyword.put(transport_opts, :socket_opts, config.ssl)
    socket = Keyword.put(config.socket, :transport_opts, transport_opts)

    %{config | socket: socket}
  end

  defp base_config() do
    base = struct(Config, Application.get_all_env(:nerves_hub_link))

    url = "wss://#{base.device_api_host}:#{base.device_api_port}/socket/websocket"

    socket = Keyword.put_new(base.socket, :url, url)

    ssl =
      base.ssl
      |> Keyword.put_new(:verify, :verify_peer)
      |> Keyword.put_new(:server_name_indication, to_charlist(base.device_api_sni))

    fwup_devpath = Nerves.Runtime.KV.get(@fwup_devpath)

    params =
      Nerves.Runtime.KV.get_all_active()
      |> Map.put("fwup_version", fwup_version())
      |> Map.put("device_api_version", @device_api_version)
      |> Map.put("console_version", @console_version)

    %{base | params: params, socket: socket, ssl: ssl, fwup_devpath: fwup_devpath}
  end

  defp do_build(configurator) when is_atom(configurator) do
    base_config()
    |> configurator.build()
  end

  defp do_build({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a) do
    apply(m, f, [base_config() | a])
  end

  defp do_build(configurator) do
    raise "[NervesHubLink] Bad Configurator - #{inspect(configurator)}"
  end

  defp fetch_default() do
    if Code.ensure_loaded?(NervesKey) do
      NervesHubLink.Configurator.NervesKey
    else
      Default
    end
  end

  defp fwup_version do
    {version_string, 0} = System.cmd("fwup", ["--version"])
    String.trim(version_string)
  end

  defp add_fwup_public_keys(config) do
    fwup_public_keys = NervesHubLink.Certificate.fwup_public_keys()

    if fwup_public_keys == [] do
      Logger.error("No fwup public keys were configured for nerves_hub_link.")
      Logger.error("This means that firmware signatures are not being checked.")
      Logger.error("nerves_hub_link will fail to apply firmware updates.")
    end

    %{config | fwup_public_keys: config.fwup_public_keys ++ fwup_public_keys}
  end
end
