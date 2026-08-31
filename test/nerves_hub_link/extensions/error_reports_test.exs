# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReportsTest do
  # Not async: the collector installs a `:logger` handler, which is global.
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.ErrorReports
  alias NervesHubLink.Extensions.ErrorReports.Collector
  alias NervesHubLink.Support.SocketStub

  setup context do
    previous_modules = Application.get_env(:nerves_hub_link, :extension_modules)
    previous_config = Application.get_env(:nerves_hub_link, :error_reports)

    Application.put_env(:nerves_hub_link, :extension_modules, [ErrorReports])

    Application.put_env(
      :nerves_hub_link,
      :error_reports,
      Keyword.merge([max_reports: 100], context[:error_reports] || [])
    )

    on_exit(fn ->
      restore(:extension_modules, previous_modules)
      restore(:error_reports, previous_config)
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)
    _ = start_supervised!({Collector, max_reports: 100})

    :ok
  end

  describe "negotiation" do
    test "is offered to a platform that has 0.1.0" do
      assert Extensions.offer(%{"error_reports" => ["0.1.0"]}) == %{"error_reports" => "0.1.0"}
    end

    # There is no older version of this extension, so a platform that names
    # nothing predates it entirely and has nothing to serve.
    test "is still offered to a platform that names nothing" do
      assert Extensions.offer(nil) == %{"error_reports" => "0.1.0"}
    end

    test "is left out when the platform does not name it" do
      refute Map.has_key?(Extensions.offer(%{"logging" => ["0.1.0"]}), "error_reports")
    end
  end

  describe "sending" do
    test "sends what collected, as one message" do
      attach()

      collect(["one", "two", "three"])

      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => reports}}
      assert Enum.map(reports, & &1["reason"]) == ["one", "two", "three"]
    end

    test "sends nothing when there is nothing to say" do
      attach()

      :ok = ErrorReports.flush()

      refute_receive {:pushed, "extensions", "error_reports:report", _payload}, 200
    end

    test "splits more than one message worth into several" do
      # The platform drops whatever a message carries past its cap of 25, so a
      # flush with 60 reports to send in one would lose 35 of them.
      attach()

      collect(Enum.map(1..60, &"report #{&1}"))

      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => first}}
      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => second}}
      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => third}}

      assert length(first) == 25
      assert length(second) == 25
      assert length(third) == 10

      assert List.first(first)["reason"] == "report 1"
      assert List.last(third)["reason"] == "report 60"
    end

    test "keeps the reports when the platform is not listening" do
      # Not attached, so the push is refused. Losing a crash to a socket that
      # was not ready is the thing the collector exists to prevent.
      collect(["one", "two"])

      _ = start_supervised!(ErrorReports)

      :ok = ErrorReports.flush()

      refute_receive {:pushed, "extensions", "error_reports:report", _payload}, 200
      assert Enum.map(Collector.take(10), & &1["reason"]) == ["one", "two"]
    end
  end

  describe "context" do
    test "device state is attached to every report in the batch" do
      attach()

      collect(["one", "two"])

      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => reports}}

      for report <- reports do
        assert %{"uptime_ms" => uptime} = report["context"]
        assert String.match?(uptime, ~r/\A\d+\z/)
      end
    end

    @tag error_reports: [context: {__MODULE__, :extra_context, []}]
    test "a configured function can add to it" do
      attach()

      collect(["one"])

      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => [report]}}
      assert report["context"]["site"] == "depot-4"
      assert report["context"]["reboot_count"] == "3"
      assert Map.has_key?(report["context"], "uptime_ms")
    end

    @tag error_reports: [context: {__MODULE__, :raising_context, []}]
    test "a context function that raises costs the report its context and nothing else" do
      attach()

      collect(["one"])

      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => [report]}}
      assert Map.has_key?(report["context"], "uptime_ms")
    end

    test "what a report already carried wins over the device's" do
      attach()

      Collector.collect(%{
        "timestamp" => "2026-08-31T10:00:00.000000Z",
        "kind" => "error",
        "reason" => "with its own",
        "frames" => [],
        "context" => %{"uptime_ms" => "from the report"}
      })

      _ = Collector.count()

      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => [report]}}
      assert report["context"]["uptime_ms"] == "from the report"
    end
  end

  describe "NervesHubLink.report_error/3" do
    test "buffers an error the application caught" do
      attach()

      NervesHubLink.report_error(%RuntimeError{message: "handled"}, [], group: "payments")

      _ = Collector.count()
      :ok = ErrorReports.flush()

      assert_receive {:pushed, "extensions", "error_reports:report", %{"reports" => [report]}}
      assert report["reason"] == "** (RuntimeError) handled"
      assert report["source"] == "manual"
      assert report["fingerprint"] == "payments"
    end

    test "is a no-op when the extension was never turned on" do
      # The collector only runs on a device that configured this. Reporting an
      # error must not become a second error.
      :ok = stop_supervised(Collector)

      assert NervesHubLink.report_error(%RuntimeError{message: "nowhere to go"}) == :ok
    end
  end

  @doc false
  @spec extra_context() :: map()
  def extra_context(), do: %{"site" => "depot-4", reboot_count: 3}

  @doc false
  @spec raising_context() :: no_return()
  def raising_context(), do: raise("no context for you")

  defp attach() do
    _ = Extensions.offer(%{"error_reports" => ["0.1.0"]})
    :ok = Extensions.attach("error_reports")

    assert_receive {:pushed, "extensions", "error_reports:attached", _payload}

    :ok
  end

  defp collect(reasons) do
    for reason <- reasons do
      Collector.collect(%{
        "timestamp" => "2026-08-31T10:00:00.000000Z",
        "kind" => "error",
        "reason" => reason,
        "frames" => []
      })
    end

    # `collect/1` is a send, so wait for the collector to have taken them all.
    _ = Collector.count()

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
