# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Configurator.SharedSecretTest do
  use ExUnit.Case, async: true

  alias Mint.WebSocket.UpgradeFailureError
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Configurator.SharedSecret

  defp config() do
    %Config{
      shared_secret: [
        product_key: "nhp_test",
        product_secret: "test-secret",
        identifier: "tnh-unit-test"
      ]
    }
  end

  defp signed_at(headers) do
    {_, value} = Enum.find(headers, fn {k, _} -> k == "x-nh-time" end)
    {ts, ""} = Integer.parse(value)
    ts
  end

  defp upgrade_failure(status_code, headers) do
    {:error,
     {:upgrade_failure,
      %{reason: %UpgradeFailureError{status_code: status_code, headers: headers}}}}
  end

  # RFC 9110 format (the form Bandit emits in every response).
  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end

  describe "headers/2" do
    test "without a server time hint, x-nh-time is the device clock" do
      first = signed_at(SharedSecret.headers(config()))
      second = signed_at(SharedSecret.headers(config()))

      # os_time advances at 1 Hz, so two near-simultaneous calls differ
      # by 0 or 1 second.
      assert (second - first) in 0..1
    end

    test "a server time hint ahead of the device clock is used as signed_at" do
      future = DateTime.utc_now() |> DateTime.add(1_000, :second)

      ts = signed_at(SharedSecret.headers(config(), future))

      assert_in_delta ts, DateTime.to_unix(future), 1
    end

    test "a server time hint behind the device clock is ignored" do
      past = DateTime.utc_now() |> DateTime.add(-10_000, :second)

      baseline = signed_at(SharedSecret.headers(config()))
      shifted = signed_at(SharedSecret.headers(config(), past))

      assert (shifted - baseline) in 0..1
    end
  end

  describe "server_time_hint/1" do
    test "returns the parsed DateTime from a 4xx upgrade failure" do
      dt = ~U[2030-01-03 12:34:56Z]
      reason = upgrade_failure(401, [{"date", http_date(dt)}])

      assert SharedSecret.server_time_hint(reason) == dt
    end

    test "is nil for non-upgrade-failure reasons" do
      assert SharedSecret.server_time_hint({:error, :closed}) == nil
      assert SharedSecret.server_time_hint(:normal) == nil
    end

    test "is nil when the response has no Date header" do
      reason = upgrade_failure(401, [{"content-type", "text/plain"}])
      assert SharedSecret.server_time_hint(reason) == nil
    end

    test "is nil when the Date header is malformed" do
      reason = upgrade_failure(401, [{"date", "not a real date"}])
      assert SharedSecret.server_time_hint(reason) == nil
    end

    test "matches only Mint's lowercased header convention" do
      # Mint lowercases response header names; server_time_hint/1 looks
      # for "date" exactly. Verify it does NOT match the capitalized form
      # so we'd notice if Mint ever stopped normalizing.
      reason = upgrade_failure(401, [{"Date", "Fri, 03 Jan 2030 12:34:56 GMT"}])
      assert SharedSecret.server_time_hint(reason) == nil
    end
  end
end
