# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ComponentsTest do
  # Not async: the tests mutate the application environment.
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.Components
  alias NervesHubLink.Support.SocketStub

  defmodule ZWaveSource do
    @behaviour NervesHubLink.Extensions.Components.Source

    @impl NervesHubLink.Extensions.Components.Source
    def networks() do
      [
        %{
          identifier: "zwave",
          label: "Z-Wave",
          metrics: ["zwave_rssi"],
          peers: [
            %{identifier: "zwave-26", label: "Motion sensor", metrics: ["battery_pct"]}
          ]
        }
      ]
    end
  end

  setup do
    previous_modules = Application.get_env(:nerves_hub_link, :extension_modules)
    previous_config = Application.get_env(:nerves_hub_link, :components)

    Application.put_env(:nerves_hub_link, :extension_modules, [Components])

    on_exit(fn ->
      restore(:extension_modules, previous_modules)
      restore(:components, previous_config)
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)

    :ok
  end

  describe "negotiation" do
    test "is offered to a platform that has 0.0.1" do
      assert Extensions.offer(%{"components" => ["0.0.1"]}) == %{"components" => "0.0.1"}
    end

    test "is left out when the platform does not name it" do
      refute Map.has_key?(Extensions.offer(%{"health" => ["0.0.1"]}), "components")
    end
  end

  describe "topology report" do
    test "sends config topology on request, without handlers" do
      put_components_config(
        assemblies: [
          %{
            identifier: "display",
            label: "Display",
            components: [
              %{
                identifier: "panel",
                metrics: ["display_fps"],
                metadata: [:panel_firmware],
                actions: [
                  %{identifier: "recalibrate", label: "Recalibrate", handler: fn -> :ok end}
                ],
                modes: [
                  %{
                    identifier: "display_mode",
                    values: ["day", "night"],
                    handler: fn _value -> :ok end
                  }
                ]
              }
            ]
          }
        ]
      )

      attach_and_request()

      assert_receive {:pushed, "extensions", "components:report", report}

      assert %{"assemblies" => [assembly], "networks" => []} = report
      assert assembly["identifier"] == "display"
      assert assembly["label"] == "Display"

      assert [component] = assembly["components"]
      assert component["identifier"] == "panel"
      assert component["metrics"] == ["display_fps"]
      assert component["metadata"] == ["panel_firmware"]

      assert [action] = component["actions"]
      assert action == %{"identifier" => "recalibrate", "label" => "Recalibrate"}

      assert [mode] = component["modes"]
      assert mode["identifier"] == "display_mode"
      assert mode["metadata_key"] == "display_mode"
      assert mode["values"] == ["day", "night"]
      refute Map.has_key?(mode, "handler")
    end

    test "merges topology from sources with config" do
      put_components_config(
        assemblies: [%{identifier: "mainboard"}],
        sources: [ZWaveSource]
      )

      attach_and_request()

      assert_receive {:pushed, "extensions", "components:report", report}

      assert [%{"identifier" => "mainboard"}] = report["assemblies"]
      assert [network] = report["networks"]
      assert network["identifier"] == "zwave"
      assert network["metrics"] == ["zwave_rssi"]
      assert [%{"identifier" => "zwave-26"}] = network["peers"]
    end

    test "drops entries without identifiers or without valid handlers" do
      put_components_config(
        assemblies: [
          %{label: "no identifier"},
          %{
            identifier: "ok",
            components: [
              %{label: "nameless"},
              %{identifier: "sensor", actions: [%{identifier: "broken", handler: "nope"}]}
            ]
          }
        ]
      )

      attach_and_request()

      assert_receive {:pushed, "extensions", "components:report", report}

      assert [%{"identifier" => "ok", "components" => [component]}] = report["assemblies"]
      assert component["identifier"] == "sensor"
      assert component["actions"] == []
    end

    test "resolves mode values given as an MFA at report time" do
      put_components_config(
        assemblies: [
          %{
            identifier: "display",
            components: [
              %{
                identifier: "panel",
                modes: [
                  %{
                    identifier: "profile",
                    values: {__MODULE__, :profile_values, []},
                    handler: fn _value -> :ok end
                  }
                ]
              }
            ]
          }
        ]
      )

      attach_and_request()

      assert_receive {:pushed, "extensions", "components:report", report}

      assert [%{"components" => [%{"modes" => [mode]}]}] = report["assemblies"]
      assert mode["values"] == ["quiet", "loud"]
    end

    test "report_topology/0 pushes a fresh report" do
      put_components_config(assemblies: [%{identifier: "mainboard"}])
      attach_and_request()
      assert_receive {:pushed, "extensions", "components:report", _report}

      assert Components.report_topology() == :ok
      assert_receive {:pushed, "extensions", "components:report", report}
      assert [%{"identifier" => "mainboard"}] = report["assemblies"]
    end
  end

  describe "actions" do
    test "runs the handler and reports an ok result" do
      test_pid = self()

      put_action_config(fn ->
        send(test_pid, :recalibrated)
        "calibration complete"
      end)

      attach_and_request()

      handle("components:action:run", %{
        "ref" => "ref-1",
        "component" => "panel",
        "action" => "recalibrate"
      })

      assert_receive :recalibrated
      assert_receive {:pushed, "extensions", "components:action:result", result}

      assert result["ref"] == "ref-1"
      assert result["component"] == "panel"
      assert result["action"] == "recalibrate"
      assert result["status"] == "ok"
      assert result["output"] == "calibration complete"
    end

    test "runs an MFA handler" do
      put_action_config({__MODULE__, :succeed, ["with args"]})

      attach_and_request()

      handle("components:action:run", %{
        "ref" => "ref-2",
        "component" => "panel",
        "action" => "recalibrate"
      })

      assert_receive {:pushed, "extensions", "components:action:result", result}
      assert result["status"] == "ok"
      assert result["output"] == "succeeded with args"
    end

    test "an unknown action reports an error without running anything" do
      put_action_config(fn -> :ok end)

      attach_and_request()

      handle("components:action:run", %{
        "ref" => "ref-3",
        "component" => "panel",
        "action" => "self-destruct"
      })

      assert_receive {:pushed, "extensions", "components:action:result", result}
      assert result["status"] == "error"
      assert result["output"] == "unknown action"
    end

    test "a raising handler reports an error result" do
      put_action_config(fn -> raise "sensor on fire" end)

      attach_and_request()

      handle("components:action:run", %{
        "ref" => "ref-4",
        "component" => "panel",
        "action" => "recalibrate"
      })

      assert_receive {:pushed, "extensions", "components:action:result", result}
      assert result["status"] == "error"
      assert result["output"] =~ "sensor on fire"
    end

    test "a stuck handler reports a timeout" do
      put_action_config(fn -> Process.sleep(:infinity) end, action_timeout: 100)

      attach_and_request()

      handle("components:action:run", %{
        "ref" => "ref-5",
        "component" => "panel",
        "action" => "recalibrate"
      })

      assert_receive {:pushed, "extensions", "components:action:result", result}, 1_000
      assert result["status"] == "error"
      assert result["output"] == "timeout"
    end
  end

  describe "modes" do
    test "applies a valid value through the handler" do
      test_pid = self()

      put_mode_config(fn value -> send(test_pid, {:mode_set, value}) end)

      attach_and_request()

      handle("components:mode:set", %{
        "ref" => "ref-6",
        "component" => "panel",
        "mode" => "display_mode",
        "value" => "night"
      })

      assert_receive {:mode_set, "night"}
      assert_receive {:pushed, "extensions", "components:mode:result", result}

      assert result["ref"] == "ref-6"
      assert result["component"] == "panel"
      assert result["mode"] == "display_mode"
      assert result["value"] == "night"
      assert result["status"] == "ok"
    end

    test "rejects a value outside the reported list" do
      test_pid = self()

      put_mode_config(fn value -> send(test_pid, {:mode_set, value}) end)

      attach_and_request()

      handle("components:mode:set", %{
        "ref" => "ref-7",
        "component" => "panel",
        "mode" => "display_mode",
        "value" => "disco"
      })

      assert_receive {:pushed, "extensions", "components:mode:result", result}
      assert result["status"] == "error"
      assert result["output"] == "invalid value"
      refute_receive {:mode_set, _value}
    end

    test "an unknown mode reports an error" do
      put_mode_config(fn _value -> :ok end)

      attach_and_request()

      handle("components:mode:set", %{
        "ref" => "ref-8",
        "component" => "panel",
        "mode" => "volume",
        "value" => "11"
      })

      assert_receive {:pushed, "extensions", "components:mode:result", result}
      assert result["status"] == "error"
      assert result["output"] == "unknown mode"
    end
  end

  @doc false
  @spec succeed(String.t()) :: String.t()
  def succeed(suffix), do: "succeeded #{suffix}"

  @doc false
  @spec profile_values() :: [String.t()]
  def profile_values(), do: ["quiet", "loud"]

  defp put_components_config(config) do
    Application.put_env(:nerves_hub_link, :components, config)
  end

  defp put_action_config(handler, extra \\ []) do
    put_components_config(
      [
        assemblies: [
          %{
            identifier: "display",
            components: [
              %{
                identifier: "panel",
                actions: [%{identifier: "recalibrate", handler: handler}]
              }
            ]
          }
        ]
      ] ++ extra
    )
  end

  defp put_mode_config(handler) do
    put_components_config(
      assemblies: [
        %{
          identifier: "display",
          components: [
            %{
              identifier: "panel",
              modes: [
                %{identifier: "display_mode", values: ["day", "night"], handler: handler}
              ]
            }
          ]
        }
      ]
    )
  end

  defp attach_and_request() do
    _ = Extensions.offer(%{"components" => ["0.0.1"]})
    :ok = Extensions.attach("components")

    assert_receive {:pushed, "extensions", "components:attached", _payload}

    # The server asks for the topology as soon as the extension attaches.
    handle("components:request", %{})

    :ok
  end

  defp handle(event, payload) do
    Extensions.handle_event(event, payload)
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
