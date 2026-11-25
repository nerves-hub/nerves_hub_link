# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.MetricsTest.CatMetrics do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Metrics.MetricSet

  @impl NervesHubLink.Extensions.Metrics.MetricSet
  def sample() do
    # Sampled from the sampler's process and from the health extension's, so
    # the test process is found by name rather than passed in.
    case Process.whereis(__MODULE__.Watcher) do
      nil -> :ok
      watcher -> send(watcher, :sampled)
    end

    %{"cats_seen" => 4}
  end
end

defmodule NervesHubLink.Extensions.MetricsTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.Alarms, as: AlarmsExtension
  alias NervesHubLink.Extensions.Health
  alias NervesHubLink.Extensions.Metrics, as: MetricsExtension
  alias NervesHubLink.Extensions.Metrics.Sampler
  alias NervesHubLink.Extensions.MetricsTest.CatMetrics
  alias NervesHubLink.Support.SocketStub

  setup context do
    previous_modules = Application.get_env(:nerves_hub_link, :extension_modules)
    previous_metrics = Application.get_env(:nerves_hub_link, :metrics)

    Process.register(self(), CatMetrics.Watcher)

    Application.put_env(:nerves_hub_link, :extension_modules, [
      AlarmsExtension,
      MetricsExtension,
      Health
    ])

    # A set of this test's own, so a reading doesn't depend on the host's CPU
    # or disk, and an interval long enough that only the test takes readings.
    Application.put_env(:nerves_hub_link, :metrics,
      metric_sets: [CatMetrics],
      sample_interval_seconds: 3_600,
      max_samples: 100
    )

    on_exit(fn ->
      restore(:extension_modules, previous_modules)
      restore(:metrics, previous_metrics)
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)
    _ = start_supervised!(Sampler)

    unless context[:offer] == false do
      _ =
        Extensions.offer(%{
          "alarms" => ["0.1.0"],
          "metrics" => ["0.1.0"],
          "health" => ["0.0.1"]
        })
    end

    :ok
  end

  describe "negotiation" do
    @describetag offer: false

    test "is offered to a platform that has 0.1.0" do
      assert %{"metrics" => "0.1.0"} = Extensions.offer(%{"metrics" => ["0.1.0"]})
    end

    test "is left out when the platform does not name it" do
      refute Map.has_key?(Extensions.offer(%{"health" => ["0.0.1"]}), "metrics")
    end
  end

  describe "attaching" do
    test "is what starts the device sampling" do
      assert Sampler.count() == 0

      attach("metrics")

      assert Sampler.count() == 1
    end
  end

  describe "a check" do
    test "sends the readings taken since the last one" do
      attach("metrics")

      :ok = Sampler.sample()

      check()

      assert_receive {:pushed, "extensions", "metrics:report", %{"reports" => reports}}
      assert length(reports) == 2
      assert Enum.all?(reports, &(&1["metrics"] == %{"cats_seen" => 4}))
      assert Enum.all?(reports, &is_binary(&1["timestamp"]))
    end

    test "leaves nothing behind once the readings have gone" do
      attach("metrics")

      check()

      assert_receive {:pushed, "extensions", "metrics:report", _payload}

      settle()
      assert Sampler.count() == 0
    end

    test "sends nothing at all when there is nothing to send" do
      attach("metrics")

      check()
      assert_receive {:pushed, "extensions", "metrics:report", _payload}

      check()
      refute_receive {:pushed, "extensions", "metrics:report", _payload}, 100
    end

    test "splits what one message may not carry across several" do
      attach("metrics")

      # The sampler starts with one reading, so this is sixty-one in all.
      Enum.each(1..60, fn _ -> :ok = Sampler.sample() end)

      check()

      assert_receive {:pushed, "extensions", "metrics:report", %{"reports" => first}}
      assert_receive {:pushed, "extensions", "metrics:report", %{"reports" => second}}

      assert length(first) == 60
      assert length(second) == 1

      settle()
      assert Sampler.count() == 0
    end
  end

  describe "flush/0" do
    test "sends what is waiting without being asked" do
      attach("metrics")

      :ok = MetricsExtension.flush()

      assert_receive {:pushed, "extensions", "metrics:report", %{"reports" => [_reading]}}
    end
  end

  describe "an unknown event" do
    test "is ignored rather than crashing the extension" do
      attach("metrics")

      Extensions.handle_event("metrics:whatever", %{})

      refute_receive {:pushed, "extensions", "metrics:report", _payload}, 100
      assert MetricsExtension.attached?()
    end
  end

  describe "alongside health" do
    test "health leaves metrics out of its reports while this is attached" do
      attach("metrics")
      attach("health")

      :ok = Health.send_report()

      assert_receive {:pushed, "extensions", "health:report", %{"value" => value}}
      refute Map.has_key?(value, :metrics)
    end

    test "health doesn't sample the metrics it is about to leave out" do
      attach("metrics")
      attach("health")

      # Whatever attaching the extension sampled
      receive do
        :sampled -> :ok
      after
        100 -> flunk("attaching should have taken a reading")
      end

      :ok = Health.send_report()

      assert_receive {:pushed, "extensions", "health:report", %{"value" => value}}

      # Collecting them would mean shelling out to `free` and `df` every check
      # to throw the answer away.
      refute_received :sampled
      refute Map.has_key?(value, :metrics)
    end

    test "health sends nothing at all once both of its keys are reported elsewhere" do
      attach("metrics")
      attach("alarms")
      attach("health")

      :ok = Health.send_report()

      # A report carrying only a timestamp still costs a message, and on the
      # platform a stored reading of nothing and a `device.health_reported`
      # event with nothing in it.
      refute_receive {:pushed, "extensions", "health:report", _payload}, 100
      refute Health.report_sent?()
    end

    test "health reports metrics itself while this is not attached" do
      attach("health")

      :ok = Health.send_report()

      assert_receive {:pushed, "extensions", "health:report", %{"value" => value}}
      assert value.metrics == %{"cats_seen" => 4}
    end
  end

  # Offered once in setup: offering again rebuilds the registry and forgets
  # what is attached.
  defp attach(name) do
    :ok = Extensions.attach(name)

    event = "#{name}:attached"
    assert_receive {:pushed, "extensions", ^event, _payload}

    :ok
  end

  defp check(), do: Extensions.handle_event("metrics:check", %{})

  # A push reaches this test before the extension has told the sampler what
  # went, so anything asking the sampler what it still holds has to wait for
  # the extension to finish first.
  defp settle(), do: :sys.get_state(MetricsExtension)

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
