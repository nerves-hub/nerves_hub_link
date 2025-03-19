# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
# credo:disable-for-this-file Credo.Check.Readability.StrictModuleLayout
defmodule NervesHubLink.Downloader.RetryConfig do
  @definition [
    max_disconnects: [
      doc: """
      Maximum number of disconnects.
      After this limit is reached the download will be stopped and will no longer be retried.
      """,
      type: :non_neg_integer,
      default: 10
    ],
    idle_timeout: [
      doc: """
      Time (in milliseconds) between chunks of data received that once elapsed will trigger a retry.
      This event counts towards the `max_disconnects` counter.
      """,
      type: :non_neg_integer,
      default: 60_000
    ],
    max_timeout: [
      doc: """
      Maximum time (in milliseconds) that a download can exist for.
      After this amount of time has elapsed, the download is canceled and the download process will crash.
      The default value is 24 hours.
      """,
      type: :non_neg_integer,
      default: 86_400_000
    ],
    time_between_retries: [
      doc: """
      Time (in milliseconds) to wait before attempting to retry a download.
      """,
      type: :non_neg_integer,
      default: 15_000
    ],
    worst_case_download_speed: [
      doc: """
      Worst case download speed specified in bytes per second.
      This is used to calculate the "worst case" ("sensible") download timeout and is
      intended to fail faster than waiting for `max_timeout` to elapse.
      For reference, LTE Cat M1 modems sometimes top out at 32 kbps (30 kbps for some slack).
      """,
      type: :non_neg_integer,
      default: 30_000
    ]
  ]

  @moduledoc """
  Download retry configuration.

  This module provides configuration for how the `Downloader` process will
  handle disconnects, errors, and timeouts.

  ## Options

    #{NimbleOptions.docs(@definition)}
  """

  require Logger

  defstruct Keyword.keys(@definition)

  @type t :: %__MODULE__{
          max_disconnects: non_neg_integer(),
          idle_timeout: non_neg_integer(),
          max_timeout: non_neg_integer(),
          time_between_retries: non_neg_integer(),
          worst_case_download_speed: non_neg_integer()
        }

  @doc """
  Validates a proposed configuration, returning the default configuration on error
  """
  @spec validate(Keyword.t()) :: t()
  def validate(opts) do
    case NimbleOptions.validate(opts, @definition) do
      {:ok, validated} ->
        struct(__MODULE__, validated)

      {:error, error} ->
        Logger.warning("Invalid retry configuration: #{inspect(error)}")

        default = NimbleOptions.validate([], @definition)

        Logger.warning("Using default retry configuration: #{inspect(default)}")

        struct(__MODULE__, default)
    end
  end
end
