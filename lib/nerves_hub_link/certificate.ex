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
defmodule NervesHubLink.Certificate do
  @moduledoc """
  Certificate management utilities
  """

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

        maybe_public_certs()
    end
  end

  # TODO: We can drop this check once OTP 25
  # is our lowest supported version
  if String.to_integer(System.otp_release()) >= 25 do
    defp maybe_public_certs(), do: :public_key.cacerts_get()
  else
    defp maybe_public_certs() do
      Logger.debug(
        "[NervesHubLink] Cannot retrieve public certs without CAStore on OTP 24 and below. Please add it as a dependency: https://hex.pm/packages/castore."
      )

      []
    end
  end
end
