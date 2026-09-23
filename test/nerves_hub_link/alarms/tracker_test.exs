# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Alarms.TrackerTest do
  # Not async: `:alarm_handler` is global to the VM.
  #
  # Driven through `:alarm_handler` directly. In this project's own tests
  # Alarmist is loaded, so `NervesHubLink.Alarms` never reaches the tracker;
  # it is the devices without Alarmist that use it.
  use ExUnit.Case, async: false

  alias NervesHubLink.Alarms.Tracker

  test "sends each change to a subscriber, stamped with when it happened" do
    start_supervised!(Tracker)
    :ok = Tracker.subscribe(self())

    before = System.monotonic_time()
    set_alarm(:tracker_event, "too hot")

    assert_receive {Tracker, :set, :tracker_event, "too hot", at} = message
    assert at >= before
    assert Tracker.change(message) == {:set, :tracker_event, "too hot", at}

    :alarm_handler.clear_alarm(:tracker_event)

    assert_receive {Tracker, :clear, :tracker_event, nil, _at}
  end

  test "remembers when each alarm set while it was running was set" do
    start_supervised!(Tracker)
    :ok = Tracker.subscribe(self())

    set_alarm(:tracker_timed, "since now")
    assert_receive {Tracker, :set, :tracker_timed, _description, at}

    assert {:tracker_timed, "since now", ^at} = find(:tracker_timed)
  end

  test "keeps the first time across a repeat" do
    start_supervised!(Tracker)
    :ok = Tracker.subscribe(self())

    set_alarm(:tracker_repeat, "first")
    assert_receive {Tracker, :set, :tracker_repeat, _description, first_at}

    set_alarm(:tracker_repeat, "second")
    assert_receive {Tracker, :set, :tracker_repeat, "second", _at}

    assert {:tracker_repeat, "second", ^first_at} = find(:tracker_repeat)
  end

  test "forgets an alarm once it clears" do
    start_supervised!(Tracker)
    :ok = Tracker.subscribe(self())

    set_alarm(:tracker_cleared, "briefly")
    :alarm_handler.clear_alarm(:tracker_cleared)
    assert_receive {Tracker, :clear, :tracker_cleared, nil, _at}

    refute find(:tracker_cleared)
  end

  # As it is here: Alarmist has replaced `:alarm_handler`'s own handler, which
  # then answers `get_alarms/0` with an error rather than a list.
  test "starts when :alarm_handler cannot say what is already set" do
    set_alarm(:tracker_earlier, "before the tracker")

    start_supervised!(Tracker)

    assert is_list(Tracker.current_alarms())
  end

  test "ignores anything that is not a change" do
    assert Tracker.change(:something_else) == :ignore
  end

  defp set_alarm(id, description) do
    :ok = :alarm_handler.set_alarm({id, description})
    on_exit(fn -> :alarm_handler.clear_alarm(id) end)
  end

  defp find(id), do: Enum.find(Tracker.current_alarms(), &(elem(&1, 0) == id))
end
