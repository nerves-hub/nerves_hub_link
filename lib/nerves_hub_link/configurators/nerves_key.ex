if Code.ensure_loaded?(NervesKey) do
  defmodule NervesHubLink.Configurator.NervesKey do
    @behaviour NervesHubLink.Configurator

    alias NervesHubLink.{Certificate, Configurator.Config}

    @impl true
    def build(%Config{} = config) do
      nk_opts = config.nerves_key || []

      bus_num = nk_opts[:i2c_bus] || 1
      certificate_pair = nk_opts[:certificate_pair] || :primary

      ssl =
        config.ssl
        |> maybe_add_cert(bus_num, certificate_pair)
        |> maybe_add_signer_cert(bus_num, certificate_pair)
        |> maybe_add_key(bus_num)
        |> maybe_add_sni(config)

      %{config | ssl: ssl}
    end

    defp maybe_add_cert(ssl, bus_num, certificate_pair) do
      Keyword.put_new_lazy(ssl, :cert, fn ->
        {:ok, i2c} = ATECC508A.Transport.I2C.init(bus_name: "i2c-#{bus_num}")

        NervesKey.device_cert(i2c, certificate_pair)
        |> X509.Certificate.to_der()
      end)
    end

    defp maybe_add_key(ssl, bus_num) do
      Keyword.put_new_lazy(ssl, :key, fn ->
        {:ok, engine} = NervesKey.PKCS11.load_engine()
        NervesKey.PKCS11.private_key(engine, i2c: bus_num)
      end)
    end

    defp maybe_add_signer_cert(ssl, bus_num, certificate_pair) do
      Keyword.put_new_lazy(ssl, :cacerts, fn ->
        {:ok, i2c} = ATECC508A.Transport.I2C.init(bus_name: "i2c-#{bus_num}")

        signer_cert =
          NervesKey.signer_cert(i2c, certificate_pair)
          |> X509.Certificate.to_der()

        [signer_cert | Certificate.ca_certs()]
      end)
    end

    defp maybe_add_sni(ssl, %{device_api_sni: sni}) do
      Keyword.put_new(ssl, :server_name_indication, to_charlist(sni))
    end
  end
end
