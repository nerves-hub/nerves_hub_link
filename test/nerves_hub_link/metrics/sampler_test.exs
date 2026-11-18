# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Metrics.SamplerTest.CatMetrics do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  @impl NervesHubLink.Extensions.Health.MetricSet
  def sample(), do: %{"cats_seen" => :counters.get(counter(), 1)}

  @doc "The reading each sample returns, so a test can tell them apart."
  @spec next() :: :ok
  def next(), do: :counters.add(counter(), 1, 1)

  defp counter() do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        counter = :counters.new(1, [])
        :ok = :persistent_term.put(__MODULE__, counter)
        counter

      counter ->
        counter
    end
  end
end

defmodule NervesHubLink.Metrics.SamplerTest.OnFire do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  @impl NervesHubLink.Extensions.Health.MetricSet
  def sample(), do: raise("the sensor is on fire")
end

defmodule NervesHubLink.Metrics.SamplerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NervesHubLink.Metrics.Sampler
  alias NervesHubLink.Metrics.SamplerTest.CatMetrics
  alias NervesHubLink.Metrics.SamplerTest.OnFire

  setup do
    previous = Application.get_env(:nerves_hub_link, :metrics)

    # A set of this test's own, so a reading doesn't depend on the host's CPU
    # or disk, and an interval long enough that only the test takes readings.
    Application.put_env(:nerves_hub_link, :metrics,
      metric_sets: [CatMetrics],
      sample_interval_seconds: 3_600
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_hub_link, :metrics, previous),
        else: Application.delete_env(:nerves_hub_link, :metrics)
    end)

    :ok
  end

  describe "sampling" do
    test "takes no readings until something is going to ask for them" do
      _ = start_supervised!({Sampler, []})

      assert Sampler.count() == 0
    end

    test "takes a reading as soon as it is asked to start" do
      start_sampler()

      assert Sampler.count() == 1
    end

    test "being asked to start again doesn't take another reading" do
      start_sampler()

      :ok = Sampler.start_sampling()

      assert Sampler.count() == 1
    end

    test "takes another when asked" do
      start_sampler()

      :ok = Sampler.sample()

      assert Sampler.count() == 2
    end

    test "holds no more than it is told to, dropping the oldest" do
      start_sampler(max_samples: 2)

      CatMetrics.next()
      :ok = Sampler.sample()
      CatMetrics.next()
      :ok = Sampler.sample()

      assert Sampler.count() == 2

      # The first reading is the one that went
      {reports, _cursor} = Sampler.take(10)
      assert Enum.map(reports, & &1["metrics"]["cats_seen"]) == [1, 2]
    end

    test "a metric set that raises costs the reading and nothing else" do
      start_sampler()

      Application.put_env(:nerves_hub_link, :metrics,
        metric_sets: [OnFire],
        sample_interval_seconds: 3_600
      )

      assert capture_log(fn -> :ok = Sampler.sample() end) =~ "could not be taken"

      assert Sampler.count() == 1
      assert Process.alive?(Process.whereis(Sampler))
    end
  end

  describe "take/1 and sent/1" do
    test "reports carry the readings and when they were taken" do
      start_sampler()

      assert {[report], _cursor} = Sampler.take(10)
      assert report["metrics"] == %{"cats_seen" => 0}
      assert {:ok, taken_at, _offset} = DateTime.from_iso8601(report["timestamp"])
      assert DateTime.diff(DateTime.utc_now(), taken_at, :second) <= 5
    end

    test "an older reading is dated before a newer one" do
      start_sampler()

      Process.sleep(10)
      :ok = Sampler.sample()

      assert {[older, newer], _cursor} = Sampler.take(10)
      assert DateTime.compare(timestamp(older), timestamp(newer)) == :lt
    end

    test "leaves the readings where they are until they are sent" do
      start_sampler()

      assert {[_reading], cursor} = Sampler.take(10)
      assert {[_still_here], ^cursor} = Sampler.take(10)

      :ok = Sampler.sent(cursor)

      assert Sampler.take(10) == {[], 0}
      assert Sampler.count() == 0
    end

    test "a reading evicted after it was taken doesn't cost an unsent one" do
      start_sampler(max_samples: 2)

      CatMetrics.next()
      :ok = Sampler.sample()

      # Both readings are taken, and then a tick lands where it would land
      # while the push is in flight, evicting the oldest of a full buffer.
      {_reports, cursor} = Sampler.take(2)
      CatMetrics.next()
      :ok = Sampler.sample()

      :ok = Sampler.sent(cursor)

      # Forgetting a count here would have forgotten the reading that arrived
      # after the take, which nothing has sent.
      assert {[report], _cursor} = Sampler.take(10)
      assert report["metrics"]["cats_seen"] == 2
      assert Sampler.count() == 1
    end

    test "answers with at most what it is asked for, oldest first" do
      start_sampler()

      CatMetrics.next()
      :ok = Sampler.sample()

      assert {[report], _cursor} = Sampler.take(1)
      assert report["metrics"]["cats_seen"] == 0
    end
  end

  describe "without a sampler running" do
    test "nothing is waiting, and nothing raises" do
      assert Sampler.take(10) == {[], 0}
      assert Sampler.count() == 0
      assert Sampler.sent(5) == :ok
      assert Sampler.sample() == :ok
    end
  end

  defp start_sampler(opts \\ []) do
    :persistent_term.erase(CatMetrics)
    sampler = start_supervised!({Sampler, opts})

    # The first reading is taken while this call is being answered, so the
    # sampler is one reading in by the time a test sets up its next one.
    :ok = Sampler.start_sampling()

    sampler
  end

  defp timestamp(report) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(report["timestamp"])
    timestamp
  end
end
