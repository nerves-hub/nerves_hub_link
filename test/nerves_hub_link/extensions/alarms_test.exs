# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.AlarmsTest do
  # Not async: alarms are global to the VM.
  use ExUnit.Case, async: false

  alias NervesHubLink.Alarms
  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.Alarms, as: AlarmsExtension
  alias NervesHubLink.Extensions.Health
  alias NervesHubLink.Support.SocketStub

  setup context do
    previous_modules = Application.get_env(:nerves_hub_link, :extension_modules)
    Application.put_env(:nerves_hub_link, :extension_modules, [AlarmsExtension, Health])
    on_exit(fn -> restore(:extension_modules, previous_modules) end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)

    unless context[:offer] == false do
      _ = Extensions.offer(%{"alarms" => ["0.1.0"], "health" => ["0.0.1"]})
    end

    :ok
  end

  describe "negotiation" do
    @describetag offer: false

    test "is offered to a platform that has 0.1.0" do
      assert %{"alarms" => "0.1.0"} = Extensions.offer(%{"alarms" => ["0.1.0"]})
    end

    test "is left out when the platform does not name it" do
      refute Map.has_key?(Extensions.offer(%{"health" => ["0.0.1"]}), "alarms")
    end
  end

  describe "the snapshot" do
    test "carries every alarm set, when NervesHub asks" do
      set_alarm(:snapshot_string, "too hot")
      set_alarm(:snapshot_term, %{celsius: 91})
      attach("alarms")

      sync()

      assert_receive {:pushed, "extensions", "alarms:snapshot", %{"alarms" => alarms}}

      assert %{"description" => "too hot"} = find(alarms, :snapshot_string)
      assert %{"description" => "%{celsius: 91}"} = find(alarms, :snapshot_term)
    end

    test "leaves out the alarms health leaves out" do
      set_alarm({:disk_almost_full, ~c"/"}, [])
      attach("alarms")

      sync()

      assert_receive {:pushed, "extensions", "alarms:snapshot", %{"alarms" => alarms}}
      refute find(alarms, {:disk_almost_full, ~c"/"})
    end

    # `config/test.exs` gives `NervesTime` no servers, so it never syncs here.
    # How a time is worked out once it has is `NervesHubLink.AlarmsTest`'s.
    test "carries no times until the clock can be trusted" do
      set_alarm(:snapshot_undated, "clock not set")
      attach("alarms")

      sync()

      assert_receive {:pushed, "extensions", "alarms:snapshot", %{"alarms" => alarms}}

      assert find(alarms, :snapshot_undated) == %{
               "alarm" => ":snapshot_undated",
               "description" => "clock not set"
             }
    end
  end

  describe "events" do
    test "an alarm is sent as it is raised, and as it clears" do
      attach("alarms")

      set_alarm(:event_alarm, "too hot")

      assert_receive {:pushed, "extensions", "alarms:raised",
                      %{"alarm" => ":event_alarm", "description" => "too hot"} = raised}

      refute Map.has_key?(raised, "raised_at")

      Alarms.clear_alarm(:event_alarm)

      assert_receive {:pushed, "extensions", "alarms:cleared", %{"alarm" => ":event_alarm"}}
    end

    test "an alarm health leaves out is not sent" do
      attach("alarms")

      set_alarm({:disk_almost_full, ~c"/"}, [])

      refute_receive {:pushed, "extensions", "alarms:raised", _payload}, 200
    end
  end

  describe "health" do
    test "leaves alarms out of its reports while the extension is attached" do
      attach("health")
      attach("alarms")

      :ok = Health.send_report()

      assert_receive {:pushed, "extensions", "health:report", %{"value" => value}}
      refute Map.has_key?(value, :alarms)
    end

    test "reports alarms itself while the extension is not attached" do
      attach("health")

      :ok = Health.send_report()

      assert_receive {:pushed, "extensions", "health:report", %{"value" => value}}
      assert Map.has_key?(value, :alarms)
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

  defp sync(), do: Extensions.handle_event("alarms:sync", %{})

  defp set_alarm(id, description) do
    :ok = Alarms.set_alarm({id, description})
    on_exit(fn -> Alarms.clear_alarm(id) end)

    wait_until(fn -> Enum.any?(Alarms.get_alarms(), &(elem(&1, 0) == id)) end)
  end

  defp find(alarms, id), do: Enum.find(alarms, &(&1["alarm"] == Alarms.name(id)))

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
