defmodule NervesHubLink.Configurator.LocalCertKey do
  @behaviour NervesHubLink.Configurator

  alias NervesHubLink.{Certificate, Configurator.Config}

  @cert_kv_path "nerves_hub_cert"
  @key_kv_path "nerves_hub_key"

  @impl NervesHubLink.Configurator
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
    cond do
      socket_opts[:cert] || socket_opts[:certfile] ->
        socket_opts

      cert = Nerves.Runtime.KV.get(@cert_kv_path) ->
        cert = Certificate.pem_to_der(cert)

        Keyword.put(socket_opts, :cert, cert)

      true ->
        Keyword.put_new(socket_opts, :certfile, "/data/nerves_hub/cert.pem")
    end
  end

  defp maybe_add_key(socket_opts) do
    cond do
      socket_opts[:key] || socket_opts[:keyfile] ->
        socket_opts

      key = Nerves.Runtime.KV.get(@key_kv_path) ->
        key = Certificate.key_pem_to_der(key)

        Keyword.put(socket_opts, :key, {:ECPrivateKey, key})

      true ->
        Keyword.put_new(socket_opts, :keyfile, "/data/nerves_hub/key.pem")
    end
  end

  defp maybe_add_sni(socket_opts, %{device_api_sni: sni}) do
    Keyword.put_new(socket_opts, :server_name_indication, to_charlist(sni))
  end
end
