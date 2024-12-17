defmodule NervesHubLink.Configurator.SharedSecret do
  @moduledoc """
  Configurator allowing authentication with a shared secret.
  """
  @behaviour NervesHubLink.Configurator

  alias Nerves.Runtime.KV
  alias NervesHubLink.Certificate
  alias NervesHubLink.Configurator.Config

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
  Generate headers for Shared Secret Auth
  """
  @spec headers(Config.t()) :: [{String.t(), String.t()}]
  def headers(%{shared_secret: shared_secret}) do
    opts =
      (shared_secret || [])
      |> Keyword.put_new(:key_digest, :sha256)
      |> Keyword.put_new(:key_iterations, 1000)
      |> Keyword.put_new(:key_length, 32)
      |> Keyword.put_new(:signature_version, "NH1")
      |> Keyword.put_new(:identifier, Nerves.Runtime.serial_number())
      # Important to use os_time as system_time is not updated by Erlang as
      # quickly. See https://www.erlang.org/doc/apps/erts/time_correction#erlang-system-time
      |> Keyword.put(:signed_at, System.os_time(:second))

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
