defmodule NervesHubLink.Configurator.Default do
  @behaviour NervesHubLink.Configurator

  alias NervesHubLink.{Certificate, Configurator.Config}

  @cert "nerves_hub_cert"
  @key "nerves_hub_key"

  @impl true
  def build(%Config{} = config) do
    ssl =
      config.ssl
      |> maybe_add_cacerts()
      |> maybe_add_cert()
      |> maybe_add_key()
      |> maybe_add_sni(config)

    %{config | ssl: ssl}
  end

  defp maybe_add_cacerts(socket_opts) do
    Keyword.put_new(socket_opts, :cacerts, Certificate.ca_certs())
  end

  defp maybe_add_cert(socket_opts) do
    if socket_opts[:cert] || socket_opts[:certfile] do
      # option already provided
      socket_opts
    else
      cert =
        Nerves.Runtime.KV.get(@cert)
        |> Certificate.pem_to_der()

      Keyword.put(socket_opts, :cert, cert)
    end
  end

  defp maybe_add_key(socket_opts) do
    if socket_opts[:key] || socket_opts[:keyfile] do
      socket_opts
    else
      key =
        Nerves.Runtime.KV.get(@key)
        |> Certificate.key_pem_to_der()

      Keyword.put(socket_opts, :key, {:ECPrivateKey, key})
    end
  end

  defp maybe_add_sni(socket_opts, %{device_api_sni: sni}) do
    Keyword.put_new(socket_opts, :server_name_indication, to_charlist(sni))
  end
end
