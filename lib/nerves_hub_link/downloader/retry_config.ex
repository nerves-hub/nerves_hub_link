defmodule NervesHubLink.Downloader.RetryConfig do
  @moduledoc """
  Configuration structure for how the Downloader server will
  handle disconnects, errors, timeouts etc
  """

  defstruct [
    # stop trying after this many disconnects
    max_disconnects: 10,

    # attempt a retry after this time
    # if no data comes in after this amount of time, disconnect and retry
    idle_timeout: 60_000,

    # if the total time since this server has started reaches this time,
    # stop trying, give up, disconnect, etc
    # started right when the gen_server starts
    # default is 24 hours as that is how long NervesHub AWS urls are signed for
    max_timeout: 86_400_000,

    # don't bother retrying until this time has passed
    time_between_retries: 15_000,

    # worst case average download speed in bits/second
    # This is used to calculate a "sensible" timeout that is shorter than `max_timeout`.
    # LTE Cat M1 modems sometimes top out at 32 kbps (30 kbps for some slack)
    worst_case_download_speed: 30_000
  ]

  @typedoc """
  maximum number of disconnects. After this limit is reached
  the download will be stopped and will no longer be retried
  """
  @type max_disconnects :: non_neg_integer()

  @typedoc """
  time in milliseconds between chunks of data received
  that once elapsed will trigger a retry. This event counts
  towards the `max_disconnects` counter
  """
  @type idle_timeout :: non_neg_integer()

  @typedoc """
  maximum time in milliseconds that a download can exist for.
  after this amount of time has elapsed, the download is canceled
  and the download process will crash
  """
  @type max_timeout :: non_neg_integer()

  @typedoc """
  time in milliseconds to wait before attempting to retry a download
  """
  @type time_between_retries :: non_neg_integer()

  @typedoc """
  worst case download speed specified in bytes per second. This is
  used to calculate the "worst case" download timeout. it is meant to
  fail faster than waiting for `max_timeout` to elapse
  """
  @type worst_case_download_speed :: non_neg_integer()

  @type t :: %__MODULE__{
          max_disconnects: max_disconnects(),
          idle_timeout: idle_timeout(),
          max_timeout: max_timeout(),
          time_between_retries: time_between_retries(),
          worst_case_download_speed: worst_case_download_speed()
        }
end
