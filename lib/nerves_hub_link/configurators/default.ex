defmodule NervesHubLink.Configurator.Default do
  @behaviour NervesHubLink.Configurator

  alias NervesHubLink.{Certificate, Configurator.Config}

  @cert "nerves_hub_cert"
  @key "nerves_hub_key"

  @impl true
  def build(%Config{} = config) do
    socket =
      get_and_update_in(
        config.socket,
        [:transport_opts],
        &{&1, add_socket_opts(&1, config)}
      )
      |> elem(1)

    %{config | socket: socket}
  end

  defp add_socket_opts(transport_opts, config) do
    transport_opts = transport_opts || []

    socket_opts =
      (transport_opts[:socket_opts] || [])
      |> maybe_add_cacerts()
      |> maybe_add_cert()
      |> maybe_add_key()
      |> maybe_add_sni(config)

    Keyword.put(transport_opts, :socket_opts, socket_opts)
  end

  defp key_pem_to_der(nil), do: <<>>

  defp key_pem_to_der(pem) do
    case X509.PrivateKey.from_pem(pem) do
      {:error, :not_found} -> <<>>
      {:ok, decoded} -> X509.PrivateKey.to_der(decoded)
    end
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
        |> key_pem_to_der()

      Keyword.put(socket_opts, :key, {:ECPrivateKey, key})
    end
  end

  defp maybe_add_sni(socket_opts, %{device_api_sni: sni}) do
    Keyword.put_new(socket_opts, :server_name_indication, to_charlist(sni))
  end
end
