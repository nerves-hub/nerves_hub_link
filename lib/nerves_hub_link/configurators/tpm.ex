# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(TPM) do
  defmodule NervesHubLink.Configurator.TPM do
    @moduledoc """
    Configurator enabling authentication via TPM.
    """

    @behaviour NervesHubLink.Configurator

    alias NervesHubLink.Certificate
    alias NervesHubLink.Configurator.Config

    require Logger

    @impl NervesHubLink.Configurator
    def build(%Config{} = config) do
      # Because :tpm is an optional dep, it does not get added to
      # .app resource files or may be started in the wrong order
      # causing failures when calling code that is not yet started.
      # So we explicitly tell the :tpm to start here to ensure
      # its available when needed. This can be removed once the fix
      # has been released
      #
      # See https://github.com/erlang/otp/pull/2675
      _ = Application.ensure_all_started(:tpm)

      tpm_opts = config.tpm || []

      probe_name = tpm_opts[:probe_name] || "tpm_tis_spi"
      key_path = tpm_opts[:key_path] || "/data/.ssh/nerves_hub_link_key"
      certificate_path = tpm_opts[:certificate_path] || "0x1000001"

      # initialize_tpm()
      _ = System.cmd("modprobe", [probe_name])
      # Give a few seconds for the TPM to initialize
      Process.sleep(2_000)

      ssl =
        config.ssl
        |> maybe_add_key(key_path)
        |> maybe_add_cert(certificate_path)
        |> maybe_add_signer_cert()

      %{config | ssl: ssl}
    end

    defp maybe_add_cert(ssl, certificate_address) do
      Keyword.put_new_lazy(ssl, :cert, fn ->
        with {:ok, cert_pem} <- TPM.nvread(certificate_address),
             {:ok, cert} <- X509.Certificate.from_pem(cert_pem) do
          X509.Certificate.to_der(cert)
        else
          _ -> raise "[NervesHubLink:TPM] TPM Unavailable"
        end
      end)
    end

    defp maybe_add_key(ssl, key_path) do
      Keyword.put_new_lazy(ssl, :key, fn ->
        case TPM.Crypto.privkey(key_path) do
          {:ok, privkey} -> privkey
          {:error, _} -> raise "[NervesHubLink:TPM] TPM Unavailable"
        end
      end)
    end

    defp maybe_add_signer_cert(ssl) do
      if ssl[:cacerts] || ssl[:cacertfile] do
        ssl
      else
        Keyword.put(ssl, :cacerts, Certificate.ca_certs())
      end
    end
  end
end
