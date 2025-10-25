# SPDX-FileCopyrightText: 2020 Jacob Arellano
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2021 Connor Rigby
# SPDX-FileCopyrightText: 2021 Frank Hunleth
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2024 Nate Shoemaker
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Configurator do
  @moduledoc """
  Behaviour for implementing a configurator.

  Implementing a new one would typically be relevant if you need a new way
  of doing authentication or other configuration. New security hardware or
  a new way to make the private key, shared secret available.

  If you want to control the firmware updates look at `NervesHubLink.Client`
  instead.
  """

  alias __MODULE__.Config
  alias Nerves.Runtime.KV
  alias NervesHubLink.Backoff
  alias NervesHubLink.UpdateManager.StreamingUpdater

  require Logger

  @device_api_version "2.3.0"
  @console_version "2.0.0"

  defmodule Config do
    @moduledoc """
    Data structure for holding configuration information provided by the configurator.
    """

    defstruct archive_public_keys: [],
              compress: true,
              connect: true,
              connect_wait_for_network: true,
              data_path: "/data/nerves-hub",
              device_api_host: nil,
              device_api_port: nil,
              device_api_sni: nil,
              fwup_devpath: "/dev/mmcblk0",
              fwup_env: [],
              fwup_public_keys: [],
              fwup_task: "upgrade",
              heartbeat_interval_msec: 30_000,
              host: "localhost",
              nerves_key: [],
              params: %{},
              rejoin_after: [5_000],
              remote_iex: false,
              remote_iex_timeout: 5 * 60 * 1000,
              request_archive_public_keys: false,
              request_fwup_public_keys: false,
              shared_secret: [],
              sni: nil,
              socket: [],
              ssl: [],
              tpm: [],
              updater: StreamingUpdater

    @type t() :: %__MODULE__{
            archive_public_keys: [binary()],
            compress: boolean(),
            connect: boolean(),
            connect_wait_for_network: boolean(),
            data_path: Path.t(),
            device_api_host: String.t(),
            device_api_port: String.t(),
            device_api_sni: charlist(),
            fwup_devpath: Path.t(),
            fwup_env: [{String.t(), String.t()}],
            fwup_public_keys: [binary()],
            fwup_task: String.t(),
            heartbeat_interval_msec: integer(),
            host: String.t(),
            nerves_key: any(),
            params: map(),
            rejoin_after: integer() | [integer()],
            remote_iex: boolean(),
            remote_iex_timeout: integer(),
            request_archive_public_keys: boolean(),
            request_fwup_public_keys: boolean(),
            shared_secret: [product_key: String.t(), product_secret: String.t()],
            sni: String.t(),
            socket: any(),
            ssl: [:ssl.tls_client_option()],
            tpm: any(),
            updater: NervesHubLink.UpdateManager.Updater.t()
          }
  end

  @callback build(%Config{}) :: Config.t()

  @fwup_devpath "nerves_fw_devpath"

  @spec build :: Config.t()
  def build() do
    configurator = fetch_configurator()

    base_config()
    |> configurator.build()
    |> add_socket_opts()
    |> add_fwup_public_keys()
    |> add_archive_public_keys()
  end

  @spec fetch_configurator :: atom()
  def fetch_configurator() do
    cond do
      configurator = Application.get_env(:nerves_hub_link, :configurator) ->
        configurator

      Code.ensure_loaded?(NervesKey) ->
        NervesHubLink.Configurator.NervesKey

      Code.ensure_loaded?(TPM) ->
        NervesHubLink.Configurator.TPM

      true ->
        NervesHubLink.Configurator.SharedSecret
    end
  end

  defp add_socket_opts(config) do
    # PhoenixClient requires these SSL options be passed as
    # [transport_opts: [socket_opts: ssl]]. So for convenience,
    # we'll bundle it all here as expected without overriding
    # any other items that may have been provided in :socket or
    # :transport_opts keys previously.
    transport_opts = config.socket[:transport_opts] || []
    transport_opts = Keyword.put(transport_opts, :socket_opts, config.ssl)

    socket =
      config.socket
      |> Keyword.put(:transport_opts, transport_opts)
      |> Keyword.put_new_lazy(:reconnect_after_msec, fn ->
        # Default retry interval
        # 1 second minimum delay that doubles up to 60 seconds. Up to 50% of
        # the delay is added to introduce jitter into the retry attempts.
        Backoff.delay_list(1000, 60000, 0.50)
      end)

    %{config | socket: socket}
  end

  defp base_config() do
    base = struct(Config, Application.get_all_env(:nerves_hub_link))

    connection_config_warnings(base)

    host =
      if base.device_api_host do
        "wss://#{base.device_api_host}:#{base.device_api_port || 443}"
      else
        if String.contains?(base.host, "://"), do: base.host, else: "wss://#{base.host}"
      end

    url = URI.parse(host) |> URI.merge("/socket/websocket")

    socket = Keyword.put_new(base.socket, :url, url)

    ssl =
      base.ssl
      |> Keyword.put_new(:verify, :verify_peer)
      |> Keyword.put_new(:versions, [:"tlsv1.2"])
      |> update_server_name_indication(base)

    fwup_devpath = KV.get(@fwup_devpath)

    params =
      KV.get_all_active()
      |> Map.put("fwup_version", fwup_version())
      |> Map.put("device_api_version", @device_api_version)
      |> Map.put("console_version", @console_version)

    %{base | params: params, socket: socket, ssl: ssl, fwup_devpath: fwup_devpath}
  end

  defp update_server_name_indication(ssl, base) do
    if base.sni || base.device_api_sni do
      Keyword.put_new(ssl, :server_name_indication, to_charlist(base.sni || base.device_api_sni))
    else
      ssl
    end
  end

  defp fwup_version() do
    {version_string, 0} = System.cmd("fwup", ["--version"])
    String.trim(version_string)
  end

  defp add_fwup_public_keys(config) do
    fwup_public_keys = for key <- config.fwup_public_keys, is_binary(key), do: key

    if Enum.empty?(fwup_public_keys) || config.request_fwup_public_keys do
      Logger.debug(
        "[NervesHubLink] Requesting public keys for firmware verification during socket connection"
      )

      params = Map.put(config.params, "fwup_public_keys", "on_connect")

      %{config | params: params}
    else
      Logger.debug(
        "[NervesHubLink] #{Enum.count(fwup_public_keys)} public key(s) for firmware verification configured"
      )

      %{config | fwup_public_keys: fwup_public_keys}
    end
  end

  defp add_archive_public_keys(config) do
    archive_public_keys = for key <- config.archive_public_keys, is_binary(key), do: key

    cond do
      config.request_archive_public_keys ->
        Logger.debug(
          "[NervesHubLink] Requesting public keys for archive verification during socket connection"
        )

        archive_public_keys_on_connect_config(config)

      Enum.any?(archive_public_keys) ->
        Logger.debug(
          "[NervesHubLink] #{Enum.count(archive_public_keys)} public key(s) for archive verification configured"
        )

        %{config | archive_public_keys: archive_public_keys}

      Enum.any?(config.fwup_public_keys) ->
        Logger.debug(
          "[NervesHubLink] Using public keys configured in `fwup_public_keys` for archive verification"
        )

        %{config | archive_public_keys: config.fwup_public_keys}

      true ->
        Logger.debug(
          "[NervesHubLink] Requesting public keys for archive verification during socket connection (no public keys configured)"
        )

        archive_public_keys_on_connect_config(config)
    end
  end

  defp archive_public_keys_on_connect_config(config) do
    params = Map.put(config.params, "archive_public_keys", "on_connect")

    %{config | params: params}
  end

  defp connection_config_warnings(base) do
    if base.device_api_host || base.device_api_port || base.device_api_sni do
      Logger.warning("[NervesHubLink] CONFIG DEPRECATION WARNINGS")

      if base.device_api_host do
        Logger.warning(
          "[NervesHubLink] `device_api_host` has been deprecated, please update your config to use `host`."
        )
      end

      if base.device_api_port do
        Logger.warning(
          "[NervesHubLink] `device_api_port` has been deprecated, please update your config to use `host` and include the port number."
        )
      end

      if base.device_api_sni do
        Logger.warning(
          "[NervesHubLink] `device_api_sni` has been deprecated, please update your config to use `sni`."
        )
      end
    end
  end
end
