# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.CollectorTest do
  # Not async: this installs a `:logger` handler, which is global.
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions.Logging.Collector

  require Logger

  defp start(opts \\ []) do
    start_supervised!({Collector, Keyword.put_new(opts, :max_lines, 5)})
    :ok
  end

  describe "collecting" do
    test "holds what the application logs" do
      start()

      Logger.info("something happened")

      assert eventually(fn -> messages() != [] end)
      assert "something happened" in messages()
    end

    test "leaves out anything below the configured level" do
      start(level: :warning)

      Logger.info("not worth reporting")
      Logger.warning("worth reporting")

      assert eventually(fn -> messages() != [] end)
      assert messages() == ["worth reporting"]
    end

    test "collects before anything is attached" do
      # The lines a device writes while booting are the ones an operator goes
      # looking for, and the extension does not exist yet when they are
      # written.
      start()

      Logger.info("during boot")

      assert eventually(fn -> "during boot" in messages() end)
    end
  end

  describe "take/1 and sent/1" do
    test "hands over the oldest lines first" do
      start()

      for n <- 1..3, do: collect("line #{n}")

      assert messages() == ["line 1", "line 2", "line 3"]
    end

    test "takes at most what was asked for" do
      start()

      for n <- 1..3, do: collect("line #{n}")

      assert Enum.map(Collector.take(2), & &1["message"]) == ["line 1", "line 2"]
    end

    test "leaves the lines where they are until they have gone" do
      # A push can fail, and lines taken out and then not sent are exactly what
      # the collector exists to prevent.
      start()

      collect("one")
      collect("two")

      assert messages() == ["one", "two"]
      assert messages() == ["one", "two"]

      :ok = Collector.sent(1)

      assert eventually(fn -> messages() == ["two"] end)
    end
  end

  describe "the bound" do
    test "drops the oldest and says how many" do
      start(max_lines: 3)

      for n <- 1..5, do: collect("line #{n}")

      assert eventually(fn -> length(messages()) == 4 end)

      [notice | kept] = messages()

      assert notice =~ "dropped 2 log lines"
      assert kept == ["line 3", "line 4", "line 5"]
    end

    test "counts the notice against what a message may carry" do
      # Otherwise the line reporting the gap is the one the platform drops for
      # making the message too long.
      start(max_lines: 3)

      for n <- 1..5, do: collect("line #{n}")

      assert eventually(fn -> length(messages()) == 4 end)
      assert length(Collector.take(2)) == 2
    end

    test "forgets the notice once it has been sent" do
      start(max_lines: 3)

      for n <- 1..5, do: collect("line #{n}")

      assert eventually(fn -> length(messages()) == 4 end)

      :ok = Collector.sent(1)

      assert eventually(fn -> length(messages()) == 3 end)
      refute Enum.any?(messages(), &(&1 =~ "dropped"))
    end
  end

  # Straight into the collector, so a test does not depend on what else in the
  # VM happens to be logging while it runs.
  defp collect(message) do
    Collector.collect(%{
      "level" => "info",
      "message" => message,
      "meta" => %{"time" => "1767000000000000"}
    })

    # `collect/1` is a send, so wait for the collector to have taken it.
    _ = Collector.count()

    :ok
  end

  defp messages(), do: Enum.map(Collector.take(100), & &1["message"])

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end
end
