# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports.ReportTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Extensions.ErrorReports.Report

  @recorded_at DateTime.to_unix(~U[2026-01-01 00:00:00.000000Z], :microsecond)

  defp crash(fun) do
    fun.()
  rescue
    error -> {error, __STACKTRACE__}
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  defp log_event(crash_reason, overrides \\ %{}) do
    Map.merge(
      %{
        level: :error,
        msg: {:string, "GenServer #PID<0.1.0> terminating"},
        meta: %{crash_reason: crash_reason, time: @recorded_at}
      },
      overrides
    )
  end

  describe "from_log_event/1" do
    test "ignores an event without a crash reason" do
      assert Report.from_log_event(%{level: :error, msg: {:string, "just a line"}, meta: %{}}) ==
               nil
    end

    test "builds a report from an exception" do
      {error, stacktrace} = crash(fn -> raise "boom" end)

      report = Report.from_log_event(log_event({error, stacktrace}))

      assert report["kind"] == "error"
      assert report["reason"] == "** (RuntimeError) boom"
      assert report["source"] == "logger"
      assert report["message"] == "GenServer #PID<0.1.0> terminating"
    end

    test "names an exit as an exit" do
      report = Report.from_log_event(log_event({:shutdown, []}))

      assert report["kind"] == "exit"
      assert report["reason"] =~ "(exit)"
    end

    test "names a throw as a throw" do
      report = Report.from_log_event(log_event({{:nocatch, :nope}, []}))

      assert report["kind"] == "throw"
      assert report["reason"] =~ "(throw)"
    end

    # The server reads this to know when the device saw the error. Sending the
    # moment of the send instead would date every report in a buffer to
    # whenever the connection came back.
    test "carries the time the runtime recorded, not the time of the send" do
      report = Report.from_log_event(log_event({:shutdown, []}))

      assert report["timestamp"] == "2026-01-01T00:00:00.000000Z"
    end

    test "falls back to now when the event has no time" do
      report =
        Report.from_log_event(
          log_event({:shutdown, []}, %{meta: %{crash_reason: {:shutdown, []}}})
        )

      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(report["timestamp"])
    end

    test "reads an OTP report as the message" do
      event = log_event({:shutdown, []}, %{msg: {:report, %{label: {:gen_server, :terminate}}}})

      assert Report.from_log_event(event)["message"] =~ "gen_server"
    end

    test "reads a format string and arguments as the message" do
      event = log_event({:shutdown, []}, %{msg: {~c"a ~ts b", [~c"middle"]}})

      assert Report.from_log_event(event)["message"] == "a middle b"
    end
  end

  describe "frames" do
    test "carry a module, a function with its arity, a file and a line" do
      {error, stacktrace} = crash(fn -> Enum.map(:nope, & &1) end)

      [frame | _rest] = Report.from_log_event(log_event({error, stacktrace}))["frames"]

      assert frame["module"] =~ "Enum"
      assert frame["function"] =~ "/"
      assert is_integer(frame["line"]) or is_nil(frame["line"])
    end

    # Nothing on the server reads these as Elixir, because the same shape has
    # to carry a Rust agent's frames too.
    test "are plain strings rather than MFAs" do
      {error, stacktrace} = crash(fn -> raise "boom" end)

      for frame <- Report.from_log_event(log_event({error, stacktrace}))["frames"] do
        assert is_binary(frame["module"]) or is_nil(frame["module"])
        assert is_binary(frame["function"])
      end
    end

    test "count arguments as the arity when a function clause did not match" do
      stacktrace = [{Foo, :bar, [1, 2, 3], [file: ~c"foo.ex", line: 4]}]

      [frame] = Report.from_log_event(log_event({:badarg, stacktrace}))["frames"]

      assert frame["function"] == "bar/3"
      assert frame["file"] == "foo.ex"
      assert frame["line"] == 4
    end

    test "are capped so a deep stacktrace cannot fill a message" do
      stacktrace = for n <- 1..50, do: {Foo, :bar, 0, [file: ~c"foo.ex", line: n]}

      assert length(Report.from_log_event(log_event({:badarg, stacktrace}))["frames"]) == 30
    end

    test "keep a frame shape they do not recognize rather than dropping it" do
      # Dropping it would shift every frame below and change the fingerprint.
      stacktrace = [:something_unexpected, {Foo, :bar, 0, [file: ~c"foo.ex", line: 1]}]

      frames = Report.from_log_event(log_event({:badarg, stacktrace}))["frames"]

      assert length(frames) == 2
      assert Enum.at(frames, 1)["function"] == "bar/0"
    end
  end

  describe "from_caught/4" do
    test "marks the report as coming from application code" do
      {error, stacktrace} = crash(fn -> raise "handled" end)

      report = Report.from_caught(:error, error, stacktrace)

      assert report["source"] == "manual"
      assert report["kind"] == "error"
      assert report["reason"] == "** (RuntimeError) handled"
    end

    test "takes a grouping key from the caller" do
      report = Report.from_caught(:error, %RuntimeError{message: "x"}, [], group: "payments")

      assert report["fingerprint"] == "payments"
    end

    test "leaves out the grouping key when none was given" do
      report = Report.from_caught(:error, %RuntimeError{message: "x"}, [])

      refute Map.has_key?(report, "fingerprint")
    end

    test "takes per-report context from the caller" do
      report =
        Report.from_caught(:error, %RuntimeError{message: "x"}, [], context: %{"order" => "42"})

      assert report["context"] == %{"order" => "42"}
    end
  end

  describe "caps" do
    test "cut an over-long reason" do
      report =
        Report.from_caught(:error, %RuntimeError{message: String.duplicate("a", 5_000)}, [])

      assert byte_size(report["reason"]) <= 2_048
    end

    # Cutting mid-character leaves a binary the server stores and nothing
    # renders.
    test "cut on a code point boundary" do
      report =
        Report.from_caught(:error, %RuntimeError{message: String.duplicate("é", 3_000)}, [])

      assert String.valid?(report["reason"])
    end
  end

  describe "put_context/2" do
    test "merges device context under anything the report already carried" do
      report = %{"reason" => "x", "context" => %{"order" => "42"}}

      merged = Report.put_context(report, %{"uptime_ms" => "1000", "order" => "ignored"})

      assert merged["context"] == %{"order" => "42", "uptime_ms" => "1000"}
    end

    test "leaves a report alone when there is no context" do
      assert Report.put_context(%{"reason" => "x"}, %{}) == %{"reason" => "x"}
      assert Report.put_context(%{"reason" => "x"}, nil) == %{"reason" => "x"}
    end
  end

  describe "dropped_notice/2" do
    test "carries a shared grouping key so a fleet's notices are one issue" do
      notice = Report.dropped_notice(7, "2026-08-31T10:00:00.000000Z")

      assert notice["fingerprint"] == "nerves_hub_link:dropped_error_reports"
      assert notice["reason"] =~ "dropped 7 error reports"
      assert notice["timestamp"] == "2026-08-31T10:00:00.000000Z"
    end
  end
end
