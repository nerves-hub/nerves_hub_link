defmodule NervesHubLink.Certificate do
  require Logger

  # Look for org here or from CLI config
  org = Application.get_env(:nerves_hub_link, :org, Application.get_env(:nerve_hub_cli, :org))

  @public_keys Application.get_env(:nerves_hub_link, :fwup_public_keys, [])
               |> NervesHubCLI.resolve_fwup_public_keys(org)

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

  # TODO: remove this in a later version
  if System.get_env("NERVES_HUB_CA_CERTS") || Application.get_env(:nerves_hub_link, :ca_certs) do
    raise("""
    Specifying `NERVES_HUB_CA_CERTS` environment variable or `config :nerves_hub_link, ca_certs: path`
    that is compiled into the module is no longer supported.

    If you are connecting to the public https://nerves-hub.org instance, simply remove env or config variable
    and the certificates from NervesHubCAStore will be used by default.

    If you are connecting to your own instance with custom CA certificates, use the `:ca_store` config
    option to specify a module with a `ca_certs/0` function that returns a list
    of DER encoded certificates:

      config :nerves_hub_link, ca_store: MyModule

    If you have the certificates in DER format, you can also explicitly set them in the `:ssl` option:

      config :nerves_hub_link, ssl: [cacerts: my_der_list]
    """)
  end

  @doc "Returns a list of der encoded CA certs"
  @spec ca_certs() :: [binary()]
  def ca_certs do
    ssl = Application.get_env(:nerves_hub_link, :ssl, [])
    ca_store = Application.get_env(:nerves_hub_link, :ca_store, NervesHubCAStore)

    # cacerts = if is_list(ssl[:cacerts]), do: ssl[:cacerts], else: []
    # if is_atom(ca_store), do: cacerts ++ ca_store.ca_certs(), else: cacerts

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

  @deprecated "Use fwup_public_keys/0 instead"
  def public_keys do
    fwup_public_keys()
  end

  def fwup_public_keys do
    @public_keys
  end
end
