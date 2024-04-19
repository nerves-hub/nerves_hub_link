defmodule NervesHubLink.Configurator do
  alias NervesHubLink.Backoff
  alias __MODULE__.{Config, Default}
  require Logger

  @device_api_version "2.0.0"
  @console_version "2.0.0"

  defmodule Config do
    defstruct connect: true,
              data_path: "/data/nerves-hub",
              device_api_host: nil,
              device_api_port: 443,
              device_api_sni: nil,
              fwup_public_keys: [],
              request_fwup_public_keys: false,
              archive_public_keys: [],
              fwup_devpath: "/dev/mmcblk0",
              fwup_env: [],
              nerves_key: [],
              params: %{},
              remote_iex: false,
              socket: [],
              ssl: []

    @type t() :: %__MODULE__{
            connect: boolean(),
            data_path: Path.t(),
            device_api_host: String.t(),
            device_api_port: String.t(),
            device_api_sni: charlist(),
            fwup_public_keys: [binary()],
            request_fwup_public_keys: boolean(),
            archive_public_keys: [binary()],
            fwup_devpath: Path.t(),
            fwup_env: [{String.t(), String.t()}],
            nerves_key: any(),
            params: map(),
            remote_iex: boolean(),
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
    |> add_archive_public_keys()
  end

  defp add_socket_opts(config) do
    # PhoenixClient requires these SSL options be passed as
    # [transport_opts: [socket_opts: ssl]]. So for convenience,
    # we'll bundle it all here as expected without overriding
    # any other items that may have been provided in :socket or
    # :transport_opts keys previously.
    transport_opts = config.socket[:transport_opts] || []
    transport_opts = Keyword.put(transport_opts, :socket_opts, config.ssl)

    socket =
      config.socket
      |> Keyword.put(:transport_opts, transport_opts)
      |> Keyword.put_new_lazy(:reconnect_after_msec, fn ->
        # Default retry interval
        # 1 second minimum delay that doubles up to 60 seconds. Up to 50% of
        # the delay is added to introduce jitter into the retry attempts.
        Backoff.delay_list(1000, 60000, 0.50)
      end)

    %{config | socket: socket}
  end

  defp base_config() do
    base = struct(Config, Application.get_all_env(:nerves_hub_link))

    url = "wss://#{base.device_api_host}:#{base.device_api_port}/socket/websocket"

    socket = Keyword.put_new(base.socket, :url, url)

    ssl =
      base.ssl
      |> Keyword.put_new(:verify, :verify_peer)
      |> Keyword.put_new(:versions, [:"tlsv1.2"])
      |> Keyword.put_new(
        :server_name_indication,
        to_charlist(base.device_api_sni || base.device_api_host)
      )

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
    fwup_public_keys = for key <- config.fwup_public_keys, is_binary(key), do: key

    if Enum.empty?(fwup_public_keys) || config.request_fwup_public_keys == true do
      Logger.info("Requesting fwup public keys")

      params = Map.put(config.params, "fwup_public_keys", "on_connect")

      %{config | params: params}
    else
      %{config | fwup_public_keys: fwup_public_keys}
    end
  end

  defp add_archive_public_keys(config) do
    archive_public_keys = for key <- config.archive_public_keys, is_binary(key), do: key

    if archive_public_keys == [] do
      Logger.debug("""
      No archive public keys were configured for nerves_hub_link.
      This means that archive signatures are not being checked.
      nerves_hub_link will fail to download archives.
      """)
    end

    %{config | archive_public_keys: archive_public_keys}
  end
end
