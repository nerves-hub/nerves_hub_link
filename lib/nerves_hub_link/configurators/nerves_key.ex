# SPDX-FileCopyrightText: 2020 Frank Hunleth
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(NervesKey) do
  defmodule NervesHubLink.Configurator.NervesKey do
    @moduledoc """
    Configurator enabling authentication via NervesKey.
    """

    @behaviour NervesHubLink.Configurator

    alias ATECC508A.Transport.I2C
    alias NervesHubLink.Certificate
    alias NervesHubLink.Configurator.Config
    alias NervesKey.PKCS11

    @impl NervesHubLink.Configurator
    def build(%Config{} = config) do
      # Because :nerves_key is an optional dep, it does not get added to
      # .app resource files or may be started in the wrong order
      # causing failures when calling code that is not yet started.
      # So we explicitly tell the :nerves_key to start here to ensure
      # its available when needed. This can be removed once the fix
      # has been released
      #
      # See https://github.com/erlang/otp/pull/2675
      _ = Application.ensure_all_started(:nerves_key)

      nk_opts = config.nerves_key || []

      bus_num = nk_opts[:i2c_bus] || 1
      certificate_pair = nk_opts[:certificate_pair] || :primary

      ssl =
        config.ssl
        |> maybe_add_cert(bus_num, certificate_pair)
        |> maybe_add_signer_cert(bus_num, certificate_pair)
        |> maybe_add_key(bus_num)

      %{config | ssl: ssl}
    end

    defp maybe_add_cert(ssl, bus_num, certificate_pair) do
      Keyword.put_new_lazy(ssl, :cert, fn ->
        {:ok, i2c} = I2C.init(bus_name: "i2c-#{bus_num}")

        NervesKey.device_cert(i2c, certificate_pair)
        |> X509.Certificate.to_der()
      end)
    end

    defp maybe_add_key(ssl, bus_num) do
      Keyword.put_new_lazy(ssl, :key, fn ->
        {:ok, engine} = PKCS11.load_engine()
        PKCS11.private_key(engine, i2c: bus_num)
      end)
    end

    defp maybe_add_signer_cert(ssl, bus_num, certificate_pair) do
      Keyword.put_new_lazy(ssl, :cacerts, fn ->
        {:ok, i2c} = I2C.init(bus_name: "i2c-#{bus_num}")

        signer_cert =
          NervesKey.signer_cert(i2c, certificate_pair)
          |> X509.Certificate.to_der()

        [signer_cert | Certificate.ca_certs()]
      end)
    end
  end
end
