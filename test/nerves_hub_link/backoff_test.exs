# SPDX-FileCopyrightText: 2021 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.BackoffTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.Utils.Backoff

  test "no jitter" do
    assert Backoff.delay_list(1000, 60000, 0) == [1000, 2000, 4000, 8000, 16000, 32000, 60000]
  end

  test "some jitter" do
    # Check that the jitter averages out to the expected value after a lot
    # of runs.
    runs = for _ <- 1..1000, do: backoff_average_jitter(1000, 60000, 0.25)
    run_average = average(runs)

    # The average of all of the runs should be around half 0.25
    assert_in_delta run_average, 0.125, 0.04
  end

  defp backoff_average_jitter(low, high, jitter) do
    zero_jitter = Backoff.delay_list(low, high, 0)
    test_jitter = Backoff.delay_list(low, high, jitter)

    Enum.zip(zero_jitter, test_jitter)
    |> Enum.map(fn {z, t} -> abs((t - z) / z) end)
    |> average()
  end

  defp average(numbers) do
    Enum.sum(numbers) / length(numbers)
  end
end
