defmodule NervesHubLink.Certificate do
  # Look for org here or from CLI config
  org = Application.get_env(:nerves_hub_link, :org, Application.get_env(:nerve_hub_cli, :org))

  @public_keys Application.get_env(:nerves_hub_link, :fwup_public_keys, [])
               |> NervesHubCLI.resolve_fwup_public_keys(org)

  ca_cert_path =
    System.get_env("NERVES_HUB_CA_CERTS") || Application.get_env(:nerves_hub_link, :ca_certs) ||
      Path.join([File.cwd!(), "ssl", "prod"])

  ca_certs =
    ca_cert_path
    |> File.ls!()
    |> Enum.map(&File.read!(Path.join(ca_cert_path, &1)))
    |> Enum.map(&X509.Certificate.to_der(X509.Certificate.from_pem!(&1)))

  if ca_certs == [], do: raise("Couldn't find NervesHub CA certificates in '#{ca_cert_path}'")

  @ca_certs ca_certs

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

  def ca_certs do
    @ca_certs
  end

  @deprecated "Use fwup_public_keys/0 instead"
  def public_keys do
    fwup_public_keys()
  end

  def fwup_public_keys do
    @public_keys
  end
end
