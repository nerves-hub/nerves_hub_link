defmodule NervesHubLink.Socket do
  require Logger

  alias NervesHubLink.Certificate

  @cert "nerves_hub_cert"
  @key "nerves_hub_key"

  @dialyzer {:nowarn_function, {:connected?, 0}}
  def connected?(pid \\ __MODULE__), do: PhoenixClient.Socket.connected?(pid)

  @spec opts(nil | keyword) :: keyword
  def opts(opts \\ nil)

  def opts(nil) do
    Application.get_env(:nerves_hub_link, :socket, [])
    |> opts()
  end

  def opts(user_config) when is_list(user_config) do
    server_name = Application.get_env(:nerves_hub_link, :device_api_host)
    server_port = Application.get_env(:nerves_hub_link, :device_api_port)
    sni = Application.get_env(:nerves_hub_link, :device_api_sni)

    url = "wss://#{server_name}:#{server_port}/socket/websocket"

    socket_opts =
      user_config
      |> Keyword.put_new(:server_name_indication, to_charlist(sni))

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
end
