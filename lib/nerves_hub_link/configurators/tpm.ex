# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(TPM) do
  defmodule NervesHubLink.Configurator.TPM do
    @moduledoc """
    Configurator enabling authentication via TPM.

    If your project is using a [TPM](https://en.wikipedia.org/wiki/Trusted_Platform_Module), and
    the [TPM](https://hex.pm/packages/tpm) Hex library, you can tell `NervesHubLink` to read the key
    and certificate from the module and assign the SSL options for you by adding it as a dependency:

        def deps() do
          [
            {:tpm, "~> 0.2.0"}
          ]
        end

    This allows your config to be simplified to:

        config :nerves_hub_link,
          host: "your.nerveshub.host"

    The TPM integration defaults include:
    - initializing the modprobe `tpm_tis_spi`
    - reading the private key using the path `/data/.ssh/nerves_hub_link_key`
    - restoring the private key from the TPM, using the memory address `"0x1000000"`, if it isn't found on the filesystem
    - and reading the certificate from the memory address `"0x1000001"`

    You can customize these options to use a different bus and certificate pair:

        config :nerves_hub_link, :tpm,
          probe_name: "tpm_tis_spi",
          key_path: "/data/.ssh"
          key_name: "nerves_hub_link_key",
          key_address: "0x1000000"
          certificate_address: "0x1000001"
          restore_key: true
    """

    @behaviour NervesHubLink.Configurator

    alias NervesHubLink.Certificate
    alias NervesHubLink.Configurator.Config

    require Logger

    @initialization_max_checks 5
    @initialization_check_delay 300

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
      key_path = tpm_opts[:key_path] || "/data/.ssh"
      key_name = tpm_opts[:key_name] || "nerves_hub_link_key"
      key_address = tpm_opts[:key_address] || "0x1000000"
      restore_key = tpm_opts[:restore_key] || true
      certificate_address = tpm_opts[:certificate_address] || "0x1000001"

      # if the TPM isn't available (modprobe failed), explode
      {_, 0} = MuonTrap.cmd("modprobe", [probe_name])

      check_tpm_initialized()

      ssl =
        config.ssl
        |> maybe_add_key(key_path, key_name, key_address, restore_key)
        |> maybe_add_cert(certificate_address)
        |> maybe_add_signer_cert()

      %{config | ssl: ssl}
    end

    defp check_tpm_initialized(check_count \\ 1) do
      case TPM.getcap(:handles_nv_index) do
        {:ok, _} ->
          :ok

        {:error, _, _} when check_count <= @initialization_max_checks ->
          Process.sleep(@initialization_check_delay)
          check_tpm_initialized(check_count + 1)

        _ ->
          raise "[NervesHubLink:TPM] TPM Unavailable"
      end
    end

    defp maybe_add_key(ssl, key_path, key_name, key_address, restore_key) do
      Keyword.put_new_lazy(ssl, :key, fn ->
        Path.join(key_path, key_name)
        |> TPM.Crypto.privkey()
        |> case do
          {:ok, privkey} ->
            restore_private_key(key_path, key_name, key_address, restore_key)
            privkey

          {:error, error} ->
            raise "[NervesHubLink:TPM] retrieving private key failed: #{inspect(error)}"
        end
      end)
    end

    defp maybe_add_cert(ssl, certificate_address) do
      Keyword.put_new_lazy(ssl, :cert, fn ->
        with {:ok, cert_pem} <- TPM.nvread(certificate_address),
             {:ok, cert} <- X509.Certificate.from_pem(cert_pem) do
          X509.Certificate.to_der(cert)
        else
          error ->
            raise "[NervesHubLink:TPM] retrieving certificate failed: #{inspect(error)}"
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

    defp restore_private_key(_key_path, _key_name, _key_address, false), do: :ok

    defp restore_private_key(path, name, address, true) do
      full_key_path = Path.join(path, name)

      with {:key_exists?, false} <- {:key_exists?, File.exists?(full_key_path)},
           {:ok, slot_data} <- TPM.nvread(address) do
        Logger.info(
          "[NervesHubLink:TPM] `#{full_key_path}` not found in file system. Restoring from TPM."
        )

        :ok = File.mkdir_p(path)
        pem = String.trim_trailing(slot_data, <<0>>)
        File.write!(full_key_path, pem)
      else
        _ -> :ok
      end
    end
  end
end
