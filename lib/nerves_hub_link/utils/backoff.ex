defmodule NervesHubLink.Utils.Backoff do
  @moduledoc false

  # Compute retry backoff intervals used by Slipstream

  @doc """
  Produce a list of integer backoff delays with jitter

  The first two parameters are minimum and maximum value. These are expected to
  be milliseconds, but this function doesn't care. The returned list will start
  with the minimum value and then double it until it reaches the maximum value.

  The third parameter is the amount of jitter to add to each delay. The value
  should be between 0 and 1. Zero adds no jitter. A value like 0.25 will add up
  to 25% of the delay amount.
  """
  @spec delay_list(integer(), integer(), number()) :: [integer()]
  def delay_list(min, max, jitter) when min > 0 and max >= min and jitter >= 0 do
    seed_rand()
    calc(min, max, jitter)
  end

  defp calc(min, max, jitter) when min >= max do
    [add_jitter(max, jitter)]
  end

  defp calc(min, max, jitter) do
    delay = add_jitter(min, jitter)
    [delay | calc(min * 2, max, jitter)]
  end

  defp add_jitter(value, jitter) do
    round(value * (1 + jitter * :rand.uniform()))
  end

  defp seed_rand() do
    # `:rand` gets seeded with the system time and counters. To avoid concern
    # that the seed could be the same across many devices, pull from a pool of
    # cryptographically secure random numbers.
    <<x::32>> = :crypto.strong_rand_bytes(4)
    _ = :rand.seed(:exsss, x)
    :ok
  end
end
