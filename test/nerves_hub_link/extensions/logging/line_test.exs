# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.LineTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Extensions.Logging.Line

  describe "from_log_event/1" do
    test "takes the message a normal log call produces" do
      line = Line.from_log_event(event(msg: {:string, ["hello ", "world"]}))

      assert line["level"] == "info"
      assert line["message"] == "hello world"
    end

    test "renders a format and its arguments" do
      # What OTP itself logs with, rather than application code.
      line = Line.from_log_event(event(msg: {~c"~s connected on ~p", [~c"device", 4001]}))

      assert line["message"] == "device connected on 4001"
    end

    test "keeps a report as something readable" do
      line = Line.from_log_event(event(msg: {:report, %{reason: :shutdown}}))

      assert line["message"] =~ "shutdown"
    end

    test "carries the level the line was written at" do
      assert Line.from_log_event(event(level: :error))["level"] == "error"
      assert Line.from_log_event(event(level: :debug))["level"] == "debug"
    end
  end

  describe "timestamps" do
    test "come from when the line was written, not when it is sent" do
      # The whole value of a line that spent a minute in a buffer, or an hour
      # of being offline.
      line = Line.from_log_event(event(meta: %{time: 1_767_000_000_000_000}))

      assert line["meta"]["time"] == "1767000000000000"
    end

    test "are always present, even from an event without one" do
      # A line without a timestamp fails validation on the server and is
      # dropped silently, so this is worth asserting rather than trusting.
      line = Line.from_log_event(event(meta: %{}))

      assert String.to_integer(line["meta"]["time"]) > 0
    end
  end

  describe "dropped_notice/2" do
    test "says how many went, at the moment the gap opened" do
      notice = Line.dropped_notice(12, "1767000000000000")

      assert notice["level"] == "warning"
      assert notice["message"] =~ "dropped 12 log lines"
      assert notice["meta"]["time"] == "1767000000000000"
    end

    test "still carries a time when the gap has no recorded moment" do
      assert String.to_integer(Line.dropped_notice(1, nil)["meta"]["time"]) > 0
    end
  end

  defp event(overrides) do
    %{level: :info, msg: {:string, "hello"}, meta: %{time: 1_767_000_000_000_000}}
    |> Map.merge(Map.new(overrides))
  end
end
