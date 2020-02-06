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
              socket: []
  end

  @callback build(%Config{}) :: %Config{}

  @spec build :: %Config{}
  def build() do
    Application.get_env(:nerves_hub_link, :configurator, fetch_default())
    |> do_build()
  end

  defp fetch_default() do
    if Code.ensure_loaded?(NervesKey) do
      NervesHubLink.Configurator.NervesKey
    else
      Default
    end
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

  defp base_config() do
    base = struct(Config, Application.get_all_env(:nerves_hub_link))

    url = "wss://#{base.device_api_host}:#{base.device_api_port}/socket/websocket"

    socket = Keyword.put_new(base.socket, :url, url)

    %{base | params: Nerves.Runtime.KV.get_all_active(), socket: socket}
  end
end
