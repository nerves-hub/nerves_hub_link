defmodule NervesHubLink.Certificate do
  # Get the fwup public keys from the app environment.
  # For now, this first requires adding a key to the environment that
  # the resolver depends on until https://github.com/nerves-hub/nerves_hub_cli/pull/125
  # is merged and released
  Application.put_env(:nerves_hub, :org, Application.get_env(:nerves_hub_link, :org))

  @public_keys Application.get_env(:nerves_hub_link, :fwup_public_keys, [])
               |> NervesHubCLI.resolve_fwup_public_keys()

  ca_cert_path =
    System.get_env("NERVES_HUB_CA_CERTS") || Application.get_env(:nerves_hub_link, :ca_certs) ||
      Application.app_dir(:nerves_hub_link, ["priv", "ca_certs"])

  ca_certs =
    ca_cert_path
    |> File.ls!()
    |> Enum.map(&File.read!(Path.join(ca_cert_path, &1)))
    |> Enum.map(&X509.Certificate.to_der(X509.Certificate.from_pem!(&1)))

  @ca_certs ca_certs

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
