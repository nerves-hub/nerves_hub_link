# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Configurator.LocalCertKey do
  @moduledoc """
  Configurator allowing authentication via locally stored certificate key.
  """

  @behaviour NervesHubLink.Configurator

  alias Nerves.Runtime.KV
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Utils.Certificate

  @cert_kv_path "nerves_hub_cert"
  @key_kv_path "nerves_hub_key"

  @impl NervesHubLink.Configurator
  def build(%Config{} = config) do
    config
    |> maybe_add_cacerts()
    |> maybe_add_cert()
    |> maybe_add_key()
    |> maybe_add_sni()
  end

  defp maybe_add_cacerts(%{ssl: ssl} = config) do
    %{config | ssl: Keyword.put_new(ssl, :cacerts, Certificate.ca_certs())}
  end

  defp maybe_add_cert(%{ssl: ssl} = config) do
    ssl =
      cond do
        ssl[:cert] || ssl[:certfile] ->
          ssl

        cert = KV.get(@cert_kv_path) ->
          cert = Certificate.pem_to_der(cert)

          Keyword.put(ssl, :cert, cert)

        true ->
          Keyword.put_new(ssl, :certfile, Path.join(config.data_path, "cert.pem"))
      end

    %{config | ssl: ssl}
  end

  defp maybe_add_key(%{ssl: ssl} = config) do
    ssl =
      cond do
        ssl[:key] || ssl[:keyfile] ->
          ssl

        key = KV.get(@key_kv_path) ->
          key = Certificate.key_pem_to_der(key)

          Keyword.put(ssl, :key, {:ECPrivateKey, key})

        true ->
          Keyword.put_new(ssl, :keyfile, Path.join(config.data_path, "key.pem"))
      end

    %{config | ssl: ssl}
  end

  defp maybe_add_sni(%{ssl: ssl, sni: sni} = config) do
    ssl = Keyword.put_new(ssl, :server_name_indication, to_charlist(sni))
    %{config | ssl: ssl}
  end
end
