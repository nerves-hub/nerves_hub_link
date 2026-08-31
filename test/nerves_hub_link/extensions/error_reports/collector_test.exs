# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports.CollectorTest do
  # Not async: this installs a `:logger` handler, which is global.
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions.ErrorReports.Collector
  alias NervesHubLink.Extensions.ErrorReports.Report

  require Logger

  defp start(opts \\ []) do
    start_supervised!({Collector, Keyword.put_new(opts, :max_reports, 5)})
    :ok
  end

  describe "what it picks up" do
    test "a process dying with an exception" do
      start()

      spawn(fn -> raise "the sensor bus is unreachable" end)

      assert eventually(fn -> reasons() != [] end)
      assert Enum.any?(reasons(), &(&1 =~ "the sensor bus is unreachable"))
    end

    test "an error logged with a crash reason by hand" do
      start()

      Logger.error("handled it", crash_reason: {%RuntimeError{message: "by hand"}, []})

      assert eventually(fn -> reasons() != [] end)
      assert Enum.any?(reasons(), &(&1 =~ "by hand"))
    end

    # An error is not every line logged at :error. Most of those are text, with
    # nothing to build a stacktrace or a fingerprint from.
    test "not an ordinary error log line" do
      start()

      Logger.error("something went wrong, but nothing crashed")

      # Give the handler the same chance it gets above.
      Process.sleep(50)

      assert reports() == []
    end

    test "not a line below error" do
      start()

      Logger.info("routine")
      Process.sleep(50)

      assert reports() == []
    end

    # A crash during boot is the one an operator wants, and the extension does
    # not exist yet when it happens. The collector runs from application start
    # for exactly this reason.
    test "crashes before anything is attached" do
      start()

      refute Process.whereis(NervesHubLink.Extensions.ErrorReports)

      spawn(fn -> raise "during boot" end)

      assert eventually(fn -> Enum.any?(reasons(), &(&1 =~ "during boot")) end)
    end

    # A bare `exit/1` from a plain process is not reported by OTP at all, so
    # what gets picked up is the exit of a supervised process, which is.
    test "a supervised process exiting abnormally" do
      start()

      {:ok, task} = Task.start(fn -> exit(:sensor_timeout) end)
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000

      assert eventually(fn -> Enum.any?(reasons(), &(&1 =~ "sensor_timeout")) end)
    end
  end

  describe "take/1 and sent/1" do
    test "hands over the oldest reports first" do
      start()

      for n <- 1..3, do: collect("report #{n}")

      assert reasons() == ["report 1", "report 2", "report 3"]
    end

    test "takes at most what was asked for" do
      start()

      for n <- 1..5, do: collect("report #{n}")

      assert length(Collector.take(2)) == 2
    end

    test "leaves the reports in place until they are acknowledged" do
      start()

      for n <- 1..3, do: collect("report #{n}")

      assert length(Collector.take(10)) == 3
      assert length(Collector.take(10)) == 3

      :ok = Collector.sent(2)

      assert eventually(fn -> reasons() == ["report 3"] end)
    end
  end

  describe "the bound" do
    test "drops the oldest past the limit and says so" do
      start(max_reports: 3)

      for n <- 1..5, do: collect("report #{n}")

      assert eventually(fn -> length(reports()) == 4 end)

      [notice | rest] = reports()

      assert notice["reason"] =~ "dropped 2 error reports"
      assert Enum.map(rest, & &1["reason"]) == ["report 3", "report 4", "report 5"]
    end

    # So the notice sorts ahead of the reports that survived it.
    test "dates the notice to when the gap opened" do
      start(max_reports: 2)

      for n <- 1..4, do: collect("report #{n}")

      assert eventually(fn -> length(reports()) == 3 end)

      [notice, first_survivor | _rest] = reports()

      assert notice["timestamp"] <= first_survivor["timestamp"]
    end

    test "forgets the notice once it has been sent" do
      start(max_reports: 3)

      for n <- 1..5, do: collect("report #{n}")

      assert eventually(fn -> length(reports()) == 4 end)

      :ok = Collector.sent(1)

      assert eventually(fn -> length(reports()) == 3 end)
      refute Enum.any?(reasons(), &(&1 =~ "dropped"))
    end
  end

  # Straight into the collector, so a test does not depend on what else in the
  # VM happens to be crashing while it runs.
  #
  # Real timestamps, not fabricated ones. The drop notice is dated from the
  # clock, so a report carrying a made-up time is not comparable with it, and
  # the ordering assertion below would hold or fail depending on the time of
  # day the suite ran.
  defp collect(reason) do
    Collector.collect(%{
      "timestamp" => Report.now(),
      "kind" => "error",
      "reason" => reason,
      "frames" => []
    })

    # `collect/1` is a send, so wait for the collector to have taken it.
    _ = Collector.count()

    :ok
  end

  defp reports(), do: Collector.take(100)
  defp reasons(), do: Enum.map(reports(), & &1["reason"])

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end
end
