defmodule NervesHubLink.Downloader.TimeoutCalculation do
  @moduledoc """
  Pure functions for dealing with timeouts
  """

  @type number_of_bytes :: non_neg_integer()
  @type bits_per_second :: non_neg_integer()

  @doc "Calculates the worst_case_timeout value based on content_length header and worst case network speed"
  @spec calculate_worst_case_timeout(number_of_bytes, bits_per_second) :: non_neg_integer()
  def calculate_worst_case_timeout(content_length, speed) do
    # need to extract milliseconds based on a speed in seconds and number of bits
    # set a max of 1 minute in case the data is smaller than the conceivably fastest speed
    round(content_length * 8 / speed * 1000) |> max(60_000)
  end
end
