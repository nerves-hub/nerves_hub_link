# SPDX-FileCopyrightText: 2023 Jon Carstens
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Configurator.SharedSecret do
  @moduledoc """
  Configurator allowing authentication with a shared secret.
  """
  @behaviour NervesHubLink.Configurator

  alias Nerves.Runtime.KV
  alias NervesHubLink.Certificate
  alias NervesHubLink.Configurator.Config

  require Logger

  @impl NervesHubLink.Configurator
  def build(%Config{ssl: ssl, socket: socket} = config) do
    ssl =
      ssl
      |> Keyword.drop([:key, :cert])
      |> Keyword.put_new(:cacerts, Certificate.ca_certs())

    # Shared Secret Auth uses a different socket path
    url = URI.merge(socket[:url], "/device-socket/websocket")

    %{config | ssl: ssl, socket: Keyword.merge(socket, headers: headers(config), url: url)}
  end

  @doc """
  Generate headers for Shared Secret Auth.

  Accepts an optional `server_time` hint — a `DateTime` previously
  observed on a server response. When the hint is ahead of the device
  clock it's used as `signed_at`; otherwise the device clock wins. This
  is how a device with a wrong local clock (no RTC, NTP not yet synced)
  can still produce a signature the server accepts on retry.
  """
  @spec headers(Config.t(), DateTime.t() | nil) :: [{String.t(), String.t()}]
  def headers(config, server_time \\ nil)

  def headers(%{shared_secret: shared_secret}, server_time) do
    opts =
      (shared_secret || [])
      |> Keyword.put_new(:key_digest, :sha256)
      |> Keyword.put_new(:key_iterations, 1000)
      |> Keyword.put_new(:key_length, 32)
      |> Keyword.put_new(:signature_version, "NH1")
      |> Keyword.put_new(:identifier, Nerves.Runtime.serial_number())
      # Important to use os_time, not system_time — Erlang's system_time
      # is corrected gradually rather than snapping to wall-clock changes.
      # See https://www.erlang.org/doc/apps/erts/time_correction#erlang-system-time
      |> Keyword.put(:signed_at, effective_signed_at(server_time))

    datetime = DateTime.from_unix!(opts[:signed_at]) |> DateTime.to_iso8601()
    Logger.info("[NervesHubLink:SharedSecret] Generating auth headers with time #{datetime}")

    alg =
      "#{opts[:signature_version]}-HMAC-#{opts[:key_digest]}-#{opts[:key_iterations]}-#{opts[:key_length]}"

    # Lookup device first then product
    # TODO: Support saving to file?
    key =
      KV.get("nh_shared_key") || opts[:key] ||
        KV.get("nh_shared_product_key") || opts[:product_key]

    secret =
      case key do
        "nhp_" <> _ ->
          KV.get("nh_shared_product_secret") || opts[:product_secret]

        _ ->
          KV.get("nh_shared_secret") || opts[:secret]
      end

    salt = create_salt(opts[:signature_version], alg, key, opts[:signed_at])

    [
      {"x-nh-alg", alg},
      {"x-nh-key", key},
      {"x-nh-time", to_string(opts[:signed_at])},
      {"x-nh-signature", Plug.Crypto.sign(secret, salt, opts[:identifier], opts)}
    ]
  end

  @doc """
  Extract a server-time hint from a Slipstream disconnect reason.

  Slipstream surfaces Mint's WebSocket upgrade failures as
  `{:error, {:upgrade_failure, %{reason: %UpgradeFailureError{headers: ...}}}}`.
  When that's the shape we get, parse the server's RFC 9110 `Date`
  header (e.g. `Sun, 06 Nov 1994 08:49:37 GMT`) into a `DateTime` and
  return it. Returns `nil` for any other reason shape, or if the Date
  header is missing or malformed.
  """
  @spec server_time_hint(term()) :: DateTime.t() | nil
  def server_time_hint({:error, {:upgrade_failure, %{reason: %{headers: headers}}}})
      when is_list(headers) do
    with {_, date_str} <- Enum.find(headers, fn {k, _v} -> k == "date" end),
         {:ok, dt} <- parse_http_date(date_str) do
      dt
    else
      _ -> nil
    end
  end

  def server_time_hint(_), do: nil

  # max(device clock, server hint). A hint older than the device clock
  # becomes a no-op, so a device whose clock has caught up since the
  # hint was learned just uses its own time.
  defp effective_signed_at(nil), do: System.os_time(:second)

  defp effective_signed_at(%DateTime{} = server_time) do
    max(System.os_time(:second), DateTime.to_unix(server_time))
  end

  defp parse_http_date(str) when is_binary(str) do
    case :httpd_util.convert_request_date(String.to_charlist(str)) do
      {{_, _, _}, {_, _, _}} = datetime ->
        epoch = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
        unix = :calendar.datetime_to_gregorian_seconds(datetime) - epoch
        DateTime.from_unix(unix)

      _ ->
        :error
    end
  end

  # Currently only support NH1
  defp create_salt(_NH1, alg, key, time) do
    """
    NH1:device-socket:shared-secret:connect

    x-nh-alg=#{alg}
    x-nh-key=#{key}
    x-nh-time=#{time}
    """
  end
end
