defmodule NervesHubLink.Configurator do
  alias __MODULE__.{Config, Default}

  defmodule Config do
    defstruct device_api_host: "device.nerves-hub.org",
              device_api_port: 443,
              device_api_sni: "device.nerves-hub.org",
              fwup_public_keys: [],
              nerves_key: [],
              params: %{},
              remote_iex: false,
              socket: [],
              ssl: []
  end

  @callback build(%Config{}) :: %Config{}

  @spec build :: %Config{}
  def build() do
    Application.get_env(:nerves_hub_link, :configurator, fetch_default())
    |> do_build()
    |> add_socket_opts()
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

    %{base | params: Nerves.Runtime.KV.get_all_active(), socket: socket, ssl: ssl}
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
end
