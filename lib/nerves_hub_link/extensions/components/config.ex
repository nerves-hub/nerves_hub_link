# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Config do
  @moduledoc false

  # How the components extension is configured:
  #
  #     config :nerves_hub_link,
  #       components: [
  #         refresher: MyApp.ComponentRefresher,
  #         refresh_timeout_seconds: 30,
  #         max_readings: 600
  #       ]
  #
  # Turning the extension on is naming it in `extension_modules`, not a key
  # here.

  require Logger

  @default_refresh_timeout_seconds 30

  # Ten messages' worth. The platform takes 60 reports a message and a message
  # a second, so this is ten seconds of sending once the device is connected,
  # and a few minutes of a busy gateway's readings while it is not.
  @default_max_readings 600

  @typedoc """
  What answers a sync: the configured `NervesHubLink.Client`, a module
  implementing `NervesHubLink.Extensions.Components.Refresher`, or an MFA.
  """
  @type refresher() :: :client | module() | {module(), atom(), list()}

  @doc """
  What to call when NervesHub asks for the device's components. The client
  unless `refresher` says otherwise.
  """
  @spec refresher() :: refresher()
  def refresher() do
    case Keyword.get(config(), :refresher) do
      nil ->
        :client

      {module, function, args} = mfa
      when is_atom(module) and is_atom(function) and is_list(args) ->
        mfa

      module when is_atom(module) and module not in [true, false] ->
        module

      other ->
        Logger.warning(
          "[NervesHubLink.Extensions.Components] ignoring refresher #{inspect(other)}: " <>
            "expected a module or {module, function, args}; using the client"
        )

        :client
    end
  end

  @doc "How long to wait for the refresher, in milliseconds."
  @spec refresh_timeout() :: pos_integer()
  def refresh_timeout() do
    case Keyword.get(config(), :refresh_timeout_seconds, @default_refresh_timeout_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> :timer.seconds(seconds)
      _invalid -> :timer.seconds(@default_refresh_timeout_seconds)
    end
  end

  @doc "How many readings to hold before dropping the oldest."
  @spec max_readings() :: pos_integer()
  def max_readings() do
    case Keyword.get(config(), :max_readings, @default_max_readings) do
      max when is_integer(max) and max > 0 -> max
      _invalid -> @default_max_readings
    end
  end

  defp config(), do: Application.get_env(:nerves_hub_link, :components, [])
end
