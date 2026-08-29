# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.Config do
  @moduledoc """
  How the Logging extension is configured.

      config :nerves_hub_link,
        logging: [
          level: :info,
          max_lines: 1000,
          interval_seconds: 60
        ]

  Shared by both versions of the extension: `level` is read by
  `NervesHubLink.Extensions.Logging` as well. The rest only means anything to
  `NervesHubLink.Extensions.Logging.Batched`, which is the version that
  collects and sends in bulk.

  Turning logging on is naming the module in `extension_modules`, not a key
  here.
  """

  # Ten messages' worth. The platform caps a message at 100 lines and allows a
  # burst of ten, so this is what one flush can actually deliver.
  @default_max_lines 1_000

  # Long enough that a fleet is not chatting, and the floor as well as the
  # default: a shorter interval spends the device's send budget on smaller
  # batches without getting more lines through.
  @default_interval_seconds 60

  @doc "The lowest level to collect."
  @spec level() :: Logger.level()
  def level(), do: Keyword.get(config(), :level, :info)

  @doc "How many lines to hold before dropping the oldest."
  @spec max_lines() :: pos_integer()
  def max_lines(), do: Keyword.get(config(), :max_lines, @default_max_lines)

  @doc """
  How long to buffer before sending, in milliseconds.

  Never less than #{@default_interval_seconds} seconds, whatever is configured.
  """
  @spec interval() :: pos_integer()
  def interval() do
    config()
    |> Keyword.get(:interval_seconds, @default_interval_seconds)
    |> max(@default_interval_seconds)
    |> :timer.seconds()
  end

  defp config(), do: Application.get_env(:nerves_hub_link, :logging, [])
end
