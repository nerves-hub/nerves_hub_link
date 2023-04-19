defmodule NervesHubLink.Certificate do
  require Logger

  def key_pem_to_der(nil), do: <<>>

  def key_pem_to_der(pem) do
    case X509.PrivateKey.from_pem(pem) do
      {:error, :not_found} -> <<>>
      {:ok, decoded} -> X509.PrivateKey.to_der(decoded)
    end
  end

  def pem_to_der(nil), do: <<>>

  def pem_to_der(cert) do
    case X509.Certificate.from_pem(cert) do
      {:error, :not_found} -> <<>>
      {:ok, decoded} -> X509.Certificate.to_der(decoded)
    end
  end

  @doc "Returns a list of der encoded CA certs"
  @spec ca_certs() :: [binary()]
  def ca_certs do
    ssl = Application.get_env(:nerves_hub_link, :ssl, [])
    ca_store = Application.get_env(:nerves_hub_link, :ca_store)

    cond do
      # prefer explicit SSL setting if available
      is_list(ssl[:cacerts]) ->
        ssl[:cacerts]

      is_atom(ca_store) ->
        ca_store.ca_certs()

      true ->
        Logger.warn(
          "[NervesHubLink] No CA store or :cacerts have been specified. Request will fail"
        )

        []
    end
  end

  def fwup_public_keys() do
    Application.get_env(:nerves_hub_link, :fwup_public_keys)
  end
end
