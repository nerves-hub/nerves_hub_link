# SPDX-FileCopyrightText: 2018 Justin Schneck
# SPDX-FileCopyrightText: 2019 Frank Hunleth
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2021 Connor Rigby
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Utils.Certificate do
  @moduledoc false

  # Certificate management utilities.

  require Logger

  @spec key_pem_to_der(nil | binary()) :: binary()
  def key_pem_to_der(nil), do: <<>>

  def key_pem_to_der(pem) do
    case X509.PrivateKey.from_pem(pem) do
      {:error, :not_found} -> <<>>
      {:ok, decoded} -> X509.PrivateKey.to_der(decoded)
    end
  end

  @spec pem_to_der(nil | binary()) :: binary()
  def pem_to_der(nil), do: <<>>

  def pem_to_der(cert) do
    case X509.Certificate.from_pem(cert) do
      {:error, :not_found} -> <<>>
      {:ok, decoded} -> X509.Certificate.to_der(decoded)
    end
  end

  @doc "Returns a list of der encoded CA certs"
  @spec ca_certs() :: [binary()]
  def ca_certs() do
    ssl = Application.get_env(:nerves_hub_link, :ssl, [])
    ca_store = Application.get_env(:nerves_hub_link, :ca_store)

    cond do
      # prefer explicit SSL setting if available
      is_list(ssl[:cacerts]) ->
        ssl[:cacerts]

      Code.ensure_loaded?(ca_store) ->
        ca_store.ca_certs()

      Code.ensure_loaded?(CAStore) ->
        Logger.debug(
          "[NervesHubLink] Using CAStore: Requests may fail if the NervesHub server certificate is not signed by a globally trusted CA."
        )

        CAStore.file_path()
        |> File.read!()
        |> X509.from_pem()
        |> Enum.map(&X509.Certificate.to_der/1)

      true ->
        Logger.debug(
          "[NervesHubLink] Using default system certificates. Requests may fail if the NervesHub server certificate is not signed by a globally trusted CA, or the installed system certificates are old."
        )

        :public_key.cacerts_get()
    end
  end
end
