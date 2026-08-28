# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.BatchedTest do
  # Not async: the collector installs a `:logger` handler, which is global.
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.Logging
  alias NervesHubLink.Extensions.Logging.Batched
  alias NervesHubLink.Extensions.Logging.Collector
  alias NervesHubLink.Support.SocketStub

  setup context do
    previous_modules = Application.get_env(:nerves_hub_link, :extension_modules)
    previous_logging = Application.get_env(:nerves_hub_link, :logging)

    Application.put_env(:nerves_hub_link, :extension_modules, [Logging, Batched])

    Application.put_env(
      :nerves_hub_link,
      :logging,
      Keyword.merge([max_lines: 250], context[:logging] || [])
    )

    on_exit(fn ->
      restore(:extension_modules, previous_modules)
      restore(:logging, previous_logging)
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)
    _ = start_supervised!({Collector, max_lines: 250})

    :ok
  end

  describe "living alongside 0.0.1" do
    test "the newer version is offered to a platform that has it" do
      assert Extensions.offer(%{"logging" => ["0.1.0", "0.0.1"]}) == %{"logging" => "0.1.0"}
    end

    test "the older version is offered to a platform that only has that" do
      # The point of keeping both. A device that could only offer 0.1.0 would
      # get no logging at all here.
      assert Extensions.offer(%{"logging" => ["0.0.1"]}) == %{"logging" => "0.0.1"}
    end

    test "the older version is offered to a platform that names nothing" do
      # Which is every NervesHub that has not learned to advertise. Those all
      # have 0.0.1 and none of them have 0.1.0.
      assert Extensions.offer(nil) == %{"logging" => "0.0.1"}
    end

    test "the version offered is the one that gets attached" do
      # Attaching the other one would have the device talking a language the
      # platform just said it does not have.
      _ = Extensions.offer(%{"logging" => ["0.0.1"]})
      :ok = Extensions.attach("logging")

      assert_receive {:pushed, "extensions", "logging:attached", _payload}
      assert Process.whereis(Logging)
      refute Process.whereis(Batched)
    end

    test "0.1.0 is attached when that is what was offered" do
      _ = Extensions.offer(%{"logging" => ["0.1.0"]})
      :ok = Extensions.attach("logging")

      assert_receive {:pushed, "extensions", "logging:attached", _payload}
      assert Process.whereis(Batched)
      refute Process.whereis(Logging)
    end
  end

  describe "sending" do
    test "sends what collected, as one message" do
      attach()

      collect(["one", "two", "three"])

      :ok = Batched.flush()

      assert_receive {:pushed, "extensions", "logging:send", %{"lines" => lines}}
      assert Enum.map(lines, & &1["message"]) == ["one", "two", "three"]
    end

    test "sends nothing when there is nothing to say" do
      attach()

      :ok = Batched.flush()

      refute_receive {:pushed, "extensions", "logging:send", _payload}, 200
    end

    test "splits more than one message worth into several" do
      # The platform drops whatever a message carries past its cap, so a flush
      # that had 250 lines to send in one would lose 150 of them.
      attach()

      collect(Enum.map(1..250, &"line #{&1}"))

      :ok = Batched.flush()

      assert_receive {:pushed, "extensions", "logging:send", %{"lines" => first}}
      assert_receive {:pushed, "extensions", "logging:send", %{"lines" => second}}
      assert_receive {:pushed, "extensions", "logging:send", %{"lines" => third}}

      assert length(first) == 100
      assert length(second) == 100
      assert length(third) == 50

      assert List.first(first)["message"] == "line 1"
      assert List.last(third)["message"] == "line 250"
    end

    test "keeps the lines when the platform is not listening" do
      # Not attached, so the push is refused. Losing the lines to a socket that
      # was not ready is the thing the collector exists to prevent.
      collect(["one", "two"])

      _ = start_supervised!(Batched)

      :ok = Batched.flush()

      refute_receive {:pushed, "extensions", "logging:send", _payload}, 200
      assert Enum.map(Collector.take(10), & &1["message"]) == ["one", "two"]
    end
  end

  defp attach() do
    _ = Extensions.offer(%{"logging" => ["0.1.0", "0.0.1"]})
    :ok = Extensions.attach("logging")

    assert_receive {:pushed, "extensions", "logging:attached", _payload}

    :ok
  end

  defp collect(messages) do
    for message <- messages do
      Collector.collect(%{
        "level" => "info",
        "message" => message,
        "meta" => %{"time" => "1767000000000000"}
      })
    end

    # `collect/1` is a send, so wait for the collector to have taken them all.
    _ = Collector.count()

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
