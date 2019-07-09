defmodule NervesHubDevice.Socket do
  require Logger

  alias NervesHubDevice.Certificate

  @cert "nerves_hub_cert"
  @key "nerves_hub_key"

  @dialyzer {:nowarn_function, {:connected?, 0}}
  def connected?(pid \\ __MODULE__), do: PhoenixClient.Socket.connected?(pid)

  @spec opts(nil | keyword) :: keyword
  def opts(opts \\ nil)

  def opts(nil) do
    Application.get_env(:nerves_hub_device, :socket, [])
    |> opts()
  end

  def opts(user_config) when is_list(user_config) do
    server_name = Application.get_env(:nerves_hub_device, :device_api_host)
    server_port = Application.get_env(:nerves_hub_device, :device_api_port)
    sni = Application.get_env(:nerves_hub_device, :device_api_sni)

    url = "wss://#{server_name}:#{server_port}/socket/websocket"

    socket_opts =
      opts_from_nerves_key_or_config(user_config)
      |> Keyword.put(:server_name_indication, to_charlist(sni))

    default_config = [
      url: url,
      serializer: Jason,
      ssl_verify: :verify_peer,
      transport_opts: [socket_opts: socket_opts]
    ]

    Keyword.merge(default_config, user_config)
  end

  def cert(opts) do
    cond do
      opts[:certfile] != nil -> {:certfile, opts[:certfile]}
      opts[:cert] != nil -> {:cert, opts[:cert]}
      true -> {:cert, Nerves.Runtime.KV.get(@cert) |> Certificate.pem_to_der()}
    end
  end

  def key(opts) do
    cond do
      opts[:keyfile] != nil ->
        {:keyfile, opts[:keyfile]}

      opts[:key] != nil ->
        {:key, opts[:key]}

      true ->
        {:key, {:ECPrivateKey, Nerves.Runtime.KV.get(@key) |> key_pem_to_der()}}
    end
  end

  defp key_pem_to_der(nil), do: <<>>

  defp key_pem_to_der(pem) do
    case X509.PrivateKey.from_pem(pem) do
      {:error, :not_found} -> <<>>
      {:ok, decoded} -> X509.PrivateKey.to_der(decoded)
    end
  end

  defp opts_from_nerves_key_or_config(user_config) do
    cacerts = user_config[:cacerts] || Certificate.ca_certs()

    with nk_opts <- Application.get_env(:nerves_hub_device, :nerves_key, []),
         true <- Keyword.get(nk_opts, :enabled, false),
         :nerves_key <- Application.get_application(NervesKey) do
      Logger.debug("[NervesHubDevice] Reading SSL options from NervesKey")
      # In the future, this may change to support other bus names
      # like "usb-something". But currently, ATECC508A and NervesKey.PKCS11
      # only support "i2c-N" scheme.
      bus_num = nk_opts[:i2c_bus] || 1
      certificate_pair = nk_opts[:certificate_pair] || :primary

      {:ok, i2c} = ATECC508A.Transport.I2C.init(bus_name: "i2c-#{bus_num}")

      if NervesKey.provisioned?(i2c) do
        {:ok, engine} = NervesKey.PKCS11.load_engine()

        cert =
          NervesKey.device_cert(i2c, certificate_pair)
          |> X509.Certificate.to_der()

        signer_cert =
          NervesKey.signer_cert(i2c, certificate_pair)
          |> X509.Certificate.to_der()

        key = NervesKey.PKCS11.private_key(engine, i2c: bus_num)
        cacerts = [signer_cert | cacerts]

        [cert: cert, key: key, cacerts: cacerts]
      else
        Logger.error("[NervesHubDevice] NervesKey isn't provisioned, so not using.")
        []
      end
    else
      _ ->
        Logger.debug("[NervesHubDevice] Using user configured SSL options")

        [cert(user_config), key(user_config), cacerts: cacerts]
    end
  end
end
