# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ComponentsTest.Refresher do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Components.Refresher

  # Tells the test it was called and with what, then does whatever the test
  # said with `will/1`: `:ok` unless told otherwise, as the default client is.
  @impl NervesHubLink.Extensions.Components.Refresher
  def refresh(opts), do: answer({:refresh, opts})

  # For a refresher configured as an MFA, called with the options appended.
  @spec listed(atom(), keyword()) :: term()
  def listed(tag, opts), do: answer({:listed, tag, opts})

  @spec answer(term()) :: term()
  def answer(call) do
    case Application.get_env(:nerves_hub_link, :test_components_pid) do
      nil -> :ok
      pid -> send(pid, {:refresher_called, call})
    end

    case Application.get_env(:nerves_hub_link, :test_components_refresh, :ok) do
      fun when is_function(fun, 0) -> fun.()
      result -> result
    end
  end

  @spec will(term()) :: :ok
  def will(result), do: Application.put_env(:nerves_hub_link, :test_components_refresh, result)
end

defmodule NervesHubLink.Extensions.ComponentsTest.Client do
  @moduledoc false
  use NervesHubLink.Client

  alias NervesHubLink.Extensions.ComponentsTest.Refresher

  @impl NervesHubLink.Client
  def components_sync(opts), do: Refresher.answer({:client, opts})
end

defmodule NervesHubLink.Extensions.ComponentsTest.DefaultClient do
  @moduledoc false
  use NervesHubLink.Client
end

defmodule NervesHubLink.Extensions.ComponentsTest do
  # Not async: the extension, its store and the socket stub are all named.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.Components
  alias NervesHubLink.Extensions.Components.Component
  alias NervesHubLink.Extensions.Components.Store
  alias NervesHubLink.Extensions.ComponentsTest.Client
  alias NervesHubLink.Extensions.ComponentsTest.DefaultClient
  alias NervesHubLink.Extensions.ComponentsTest.Refresher
  alias NervesHubLink.Support.SocketStub

  doctest Component

  @probe %{
    namespace: "zigbee",
    vendor: "1286",
    model: "SNZB-02D",
    serial: "00:12:4b:00:2a:3f:91:c7",
    name: "Freezer probe A",
    vendor_name: "Sonoff",
    firmware_version: "2.1.0"
  }

  @mcu %{
    namespace: "mcu",
    vendor: "raspberrypi",
    model: "rp2350",
    serial: "e6614c311b4a2c2f",
    address: "UART0"
  }

  @lock %{
    namespace: "zwave",
    vendor: "0129",
    model: "8002:0600",
    serial: "34028-23669-20938-46346-33746-07431-56821-14553",
    name: "Office lock"
  }

  # The contract's delays, scaled down so a test needn't wait five seconds for
  # a snapshot. What is tested is the order things go out in, not the clock.
  @snapshot_delay_ms 50
  @snapshot_max_delay_ms 300
  @readings_interval_ms 50

  setup context do
    previous_modules = Application.get_env(:nerves_hub_link, :extension_modules)
    previous_config = Application.get_env(:nerves_hub_link, :components)
    previous_client = Application.get_env(:nerves_hub_link, :client)

    Application.put_env(:nerves_hub_link, :extension_modules, [Components])
    Application.put_env(:nerves_hub_link, :components, context[:components] || [])
    # The suite's client is a Mox mock, which only answers the process that
    # set an expectation, and the refresher runs in a process of its own.
    Application.put_env(:nerves_hub_link, :client, context[:client] || Client)
    Application.put_env(:nerves_hub_link, :test_components_pid, self())

    on_exit(fn ->
      Application.delete_env(:nerves_hub_link, :test_components_refresh)
      Application.delete_env(:nerves_hub_link, :test_components_pid)
      restore(:extension_modules, previous_modules)
      restore(:components, previous_config)
      restore(:client, previous_client)
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)

    _ =
      start_supervised!(
        {Store,
         max_readings: context[:max_readings] || 100,
         snapshot_delay_ms: @snapshot_delay_ms,
         snapshot_max_delay_ms: @snapshot_max_delay_ms,
         readings_interval_ms: @readings_interval_ms}
      )

    :ok
  end

  describe "negotiation" do
    test "is offered to a platform that has 0.1.0" do
      assert Extensions.offer(%{"components" => ["0.1.0"]}) == %{"components" => "0.1.0"}
    end

    test "is left out when the platform does not name it" do
      refute Map.has_key?(Extensions.offer(%{"health" => ["0.0.1"]}), "components")
    end

    test "is off unless named in extension_modules" do
      Application.delete_env(:nerves_hub_link, :extension_modules)

      refute Components in Extensions.configured_modules()
    end

    test "its store is started with the connection when it is configured" do
      {:ok, {_flags, specs}} =
        NervesHubLink.Supervisor.init(config: %NervesHubLink.Configurator.Config{})

      assert Enum.any?(specs, &match?(%{start: {Store, _fun, _args}}, &1))
    end
  end

  describe "Component.new/1" do
    test "writes a component with string keys, leaving out what isn't given" do
      assert {:ok, entry} = Component.new(@probe)

      assert entry == %{
               "namespace" => "zigbee",
               "vendor" => "1286",
               "model" => "SNZB-02D",
               "serial" => "00:12:4b:00:2a:3f:91:c7",
               "name" => "Freezer probe A",
               "vendor_name" => "Sonoff",
               "firmware_version" => "2.1.0"
             }
    end

    test "accepts string keys, as a component read from JSON has" do
      assert {:ok, %{"namespace" => "usb", "serial" => "1-1.3"}} =
               Component.new(%{
                 "namespace" => "usb",
                 "vendor" => "0403",
                 "model" => "6001",
                 "serial" => "1-1.3"
               })
    end

    test "accepts an atom namespace" do
      assert {:ok, %{"namespace" => "ble"}} = Component.new(%{@mcu | namespace: :ble})
    end

    for field <- [:namespace, :vendor, :model, :serial] do
      test "refuses a component without #{field}" do
        assert {:error, reason} = Component.new(Map.delete(@probe, unquote(field)))
        assert reason =~ "#{unquote(field)} is missing"
      end

      test "refuses an empty #{field}" do
        assert {:error, _reason} = Component.new(Map.put(@probe, unquote(field), ""))
      end
    end

    test "refuses a required field that isn't a string" do
      assert {:error, reason} = Component.new(%{@probe | serial: 1234})
      assert reason =~ "serial must be a string"
    end

    test "refuses a namespace NervesHub doesn't accept" do
      for namespace <- ["Zigbee", "2wave", "z-wave", "_zigbee", String.duplicate("a", 33)] do
        assert {:error, reason} = Component.new(%{@probe | namespace: namespace})
        assert reason =~ "namespace"
      end

      assert {:ok, _entry} = Component.new(%{@probe | namespace: String.duplicate("a", 32)})
    end

    test "refuses a required field longer than 255 characters, counted as NervesHub counts them" do
      assert {:ok, _entry} = Component.new(%{@probe | serial: String.duplicate("a", 255)})
      assert {:error, reason} = Component.new(%{@probe | serial: String.duplicate("a", 256)})
      assert reason =~ "longer than 255"

      # 128 graphemes, but 256 code points, and PostgreSQL counts code points.
      combining = String.duplicate("é", 128)
      assert String.length(combining) == 128
      assert {:error, _reason} = Component.new(%{@probe | serial: combining})
    end

    test "refuses a string that isn't UTF-8, which NervesHub can't store" do
      assert {:error, reason} = Component.new(%{@probe | serial: <<0xFF, 0xFE>>})
      assert reason =~ "UTF-8"
    end

    test "leaves out an empty optional field, which NervesHub reads as absent" do
      assert {:ok, entry} = Component.new(%{@probe | name: ""})
      refute Map.has_key?(entry, "name")
    end

    test "drops an optional field NervesHub would refuse, and keeps the component" do
      # A component listed without its name beats one shown as Missing.
      {result, log} =
        with_log(fn -> Component.new(%{@probe | name: String.duplicate("x", 300)}) end)

      assert {:ok, entry} = result
      refute Map.has_key?(entry, "name")
      assert entry["serial"] == "00:12:4b:00:2a:3f:91:c7"
      assert log =~ "dropped name"

      {result, _log} = with_log(fn -> Component.new(Map.put(@probe, :firmware_version, 2)) end)
      assert {:ok, entry} = result
      refute Map.has_key?(entry, "firmware_version")
    end

    test "sends reachable only when it is said, and only as a boolean" do
      assert {:ok, entry} = Component.new(@probe)
      refute Map.has_key?(entry, "reachable")

      assert {:ok, %{"reachable" => false}} = Component.new(Map.put(@probe, :reachable, false))

      {result, log} = with_log(fn -> Component.new(Map.put(@probe, :reachable, "false")) end)
      assert {:ok, entry} = result
      refute Map.has_key?(entry, "reachable")
      assert log =~ "dropped reachable"
    end

    test "writes last_seen_at as ISO 8601 with an offset" do
      assert {:ok, %{"last_seen_at" => "2026-11-24T10:42:11Z"}} =
               Component.new(Map.put(@probe, :last_seen_at, ~U[2026-11-24 10:42:11Z]))

      assert {:ok, %{"last_seen_at" => "2026-11-24T21:42:11+11:00"}} =
               Component.new(Map.put(@probe, :last_seen_at, "2026-11-24T21:42:11+11:00"))
    end

    test "drops a last_seen_at without an offset" do
      for at <- [~N[2026-11-24 10:42:11], "2026-11-24T10:42:11", "yesterday"] do
        {result, log} = with_log(fn -> Component.new(Map.put(@probe, :last_seen_at, at)) end)

        assert {:ok, entry} = result
        refute Map.has_key?(entry, "last_seen_at")
        assert log =~ "dropped last_seen_at"
      end
    end

    test "writes state as strings, accepting atoms" do
      assert {:ok, %{"state" => %{"lock" => "unlocked", "door" => "closed"}}} =
               Component.new(Map.put(@lock, :state, %{lock: :unlocked, door: "closed"}))
    end

    test "sends an empty state, which says the component has none" do
      assert {:ok, %{"state" => %{}}} = Component.new(Map.put(@lock, :state, %{}))
    end

    test "drops a state NervesHub would refuse, and keeps the rest" do
      state = %{
        "lock" => "unlocked",
        "Lock" => "locked",
        "door" => "",
        "mode" => String.duplicate("x", 65)
      }

      {result, log} = with_log(fn -> Component.new(Map.put(@lock, :state, state)) end)

      assert {:ok, %{"state" => %{"lock" => "unlocked"} = kept}} = result
      assert map_size(kept) == 1
      assert log =~ "dropped a state"
    end

    test "keeps at most 8 states, the first by name" do
      state =
        Map.new(
          1..10,
          &{"state_#{&1 |> Integer.to_string() |> String.pad_leading(2, "0")}", "on"}
        )

      {result, log} = with_log(fn -> Component.new(Map.put(@lock, :state, state)) end)

      assert {:ok, %{"state" => kept}} = result
      assert Map.keys(kept) == Enum.map(1..8, &"state_0#{&1}")
      assert log =~ "more than 8 states"
    end

    test "ignores fields the contract doesn't have" do
      assert {:ok, entry} = Component.new(Map.put(@probe, :color, "blue"))
      refute Map.has_key?(entry, "color")
    end
  end

  describe "answering components:sync" do
    test "answers with the set" do
      :ok = Components.set_components([@probe, @mcu])
      attach()

      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => components}}

      # Sorted by namespace and serial, so the same set is always sent the
      # same way.
      assert components == [
               %{
                 "namespace" => "mcu",
                 "vendor" => "raspberrypi",
                 "model" => "rp2350",
                 "serial" => "e6614c311b4a2c2f",
                 "address" => "UART0"
               },
               %{
                 "namespace" => "zigbee",
                 "vendor" => "1286",
                 "model" => "SNZB-02D",
                 "serial" => "00:12:4b:00:2a:3f:91:c7",
                 "name" => "Freezer probe A",
                 "vendor_name" => "Sonoff",
                 "firmware_version" => "2.1.0"
               }
             ]
    end

    test "answers with an empty set when the device has none" do
      attach()

      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => []}}
    end

    test "answers every sync, even one asking for what was just sent" do
      :ok = Components.set_components([@probe])
      attach()

      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", first}

      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", ^first}
    end

    test "answers a refresh straight away when there's no refresher" do
      :ok = Components.set_components([@probe])
      attach()

      sync(%{"refresh" => true})

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [_probe]}}
    end

    test "a set made before NervesHub asked is what it gets" do
      # Applications find their components at boot, long before NervesHub
      # attaches the extension. Nothing is sent until then.
      :ok = Components.set_components([@probe])

      refute_receive {:pushed, "extensions", "components:snapshot", _payload},
                     @snapshot_delay_ms * 3

      attach()
      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [_probe]}}
    end
  end

  describe "sending a changed set" do
    setup do
      attach()
      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => []}}

      :ok
    end

    test "sends one snapshot for several changes in a row" do
      :ok = Components.put_component(@probe)
      :ok = Components.put_component(@mcu)
      :ok = Components.put_component(@lock)

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => components}}
      assert length(components) == 3

      refute_receive {:pushed, "extensions", "components:snapshot", _payload},
                     @snapshot_delay_ms * 3
    end

    test "waits for the changes to stop, but not for ever" do
      # A component flapping between reachable and not would otherwise hold
      # the snapshot back indefinitely.
      started = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          for n <- 1..20 do
            :ok = Components.put_component(Map.put(@probe, :reachable, rem(n, 2) == 0))
            Process.sleep(div(@snapshot_delay_ms, 2))
          end
        end)

      assert_receive {:pushed, "extensions", "components:snapshot", _payload},
                     @snapshot_max_delay_ms * 2

      assert System.monotonic_time(:millisecond) - started < @snapshot_max_delay_ms * 2

      Task.await(task)
    end

    test "doesn't send a set NervesHub already has" do
      :ok = Components.set_components([@probe])
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}

      :ok = Components.set_components([@probe])
      :ok = Components.put_component(@mcu)
      :ok = Components.delete_component("mcu", "e6614c311b4a2c2f")

      refute_receive {:pushed, "extensions", "components:snapshot", _payload},
                     @snapshot_delay_ms * 3
    end

    test "put_component/1 replaces the component with the same namespace and serial" do
      :ok = Components.set_components([@probe, @mcu])
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}

      :ok =
        Components.put_component(
          %{@probe | firmware_version: "2.2.0"}
          |> Map.put(:reachable, false)
        )

      assert_receive {:pushed, "extensions", "components:snapshot",
                      %{"components" => [_mcu, probe]}}

      assert probe["firmware_version"] == "2.2.0"
      assert probe["reachable"] == false
    end

    test "delete_component/2 takes it out of the set" do
      :ok = Components.set_components([@probe, @mcu])
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}

      :ok = Components.delete_component(:mcu, "e6614c311b4a2c2f")

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [probe]}}
      assert probe["namespace"] == "zigbee"
    end

    test "a set that comes back empty says the device has none" do
      :ok = Components.set_components([@probe])
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}

      :ok = Components.set_components([])

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => []}}
    end
  end

  describe "bad entries in a set" do
    setup do
      attach()
      :ok
    end

    test "are left out and logged, and the rest are sent" do
      log =
        capture_log(fn ->
          :ok =
            Components.set_components([
              @probe,
              Map.delete(@mcu, :serial),
              %{@lock | namespace: "Z-Wave"}
            ])
        end)

      assert log =~ "left out a component: serial is missing"
      assert log =~ "left out a component: namespace"

      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [probe]}}
      assert probe["namespace"] == "zigbee"
    end

    test "a component listed twice is sent once" do
      log =
        capture_log(fn ->
          :ok = Components.set_components([@probe, %{@probe | name: "A second name"}])
        end)

      assert log =~ "listed more than once"

      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [probe]}}
      assert probe["name"] == "Freezer probe A"
    end

    test "past 500 components the rest are left out" do
      components = for n <- 1..502, do: %{@mcu | serial: "chip-#{n}"}

      log = capture_log(fn -> :ok = Components.set_components(components) end)
      assert log =~ "NervesHub accepts 500"

      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => sent}}
      assert length(sent) == 500
    end

    test "put_component/1 says why it refused one" do
      {result, _log} = with_log(fn -> Components.put_component(Map.delete(@probe, :model)) end)
      assert {:error, "model is missing"} = result
    end

    test "put_component/1 refuses a 501st component" do
      :ok = Components.set_components(for n <- 1..500, do: %{@mcu | serial: "chip-#{n}"})

      assert Components.put_component(@probe) == {:error, :too_many_components}
      # Replacing one it already has is still fine.
      assert Components.put_component(Map.merge(@mcu, %{serial: "chip-1", name: "Renamed"})) ==
               :ok
    end
  end

  describe "asking the client" do
    setup do
      connected([@probe])
      assert_received {:refresher_called, {:client, refresh: false}}

      :ok
    end

    test "every sync asks the client, saying whether it's a refresh" do
      sync()
      assert_receive {:refresher_called, {:client, refresh: false}}
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}

      sync(%{"refresh" => true})
      assert_receive {:refresher_called, {:client, refresh: true}}
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}
    end

    test "answers with the set the client returns" do
      Refresher.will({:ok, [@mcu]})

      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [mcu]}}
      assert mcu["namespace"] == "mcu"
    end

    test "answers with the set as it stands when the client returns :ok" do
      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [probe]}}
      assert probe["namespace"] == "zigbee"
    end

    test "answers with what the client set itself" do
      Refresher.will(fn ->
        :ok = Components.put_component(Map.put(@probe, :reachable, false))
        :ok
      end)

      sync(%{"refresh" => true})

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [probe]}}
      assert probe["reachable"] == false
    end

    test "answers with the set as it stands when the client fails" do
      Refresher.will({:error, :radio_offline})

      log =
        capture_log(fn ->
          sync()

          assert_receive {:pushed, "extensions", "components:snapshot",
                          %{"components" => [_probe]}}
        end)

      assert log =~ "radio_offline"
    end

    test "answers with the set as it stands when the client raises" do
      Refresher.will(fn -> raise "the coordinator is on fire" end)

      log =
        capture_log(fn ->
          sync()

          assert_receive {:pushed, "extensions", "components:snapshot",
                          %{"components" => [_probe]}}
        end)

      assert log =~ "the coordinator is on fire"
      assert Process.alive?(Process.whereis(Components))
    end

    @tag components: [refresh_timeout_seconds: 1]
    test "answers with the set as it stands when the client takes too long" do
      Refresher.will(fn -> Process.sleep(:infinity) end)

      log =
        capture_log(fn ->
          sync()

          assert_receive {:pushed, "extensions", "components:snapshot",
                          %{"components" => [_probe]}},
                         2_000
        end)

      assert log =~ "took too long"
    end

    test "a refresh asked for while a plain sync is being answered gets its own run" do
      # The run already going won't check on the components, so it can't
      # answer a request to look again.
      test_pid = self()

      Refresher.will(fn ->
        send(test_pid, {:running, self()})

        receive do
          :go -> :ok
        end
      end)

      sync()
      assert_receive {:running, first}

      sync(%{"refresh" => true})
      sync()
      send(first, :go)

      assert_receive {:pushed, "extensions", "components:snapshot", _payload}
      assert_receive {:refresher_called, {:client, refresh: true}}
      assert_receive {:running, second}
      send(second, :go)

      assert_receive {:pushed, "extensions", "components:snapshot", _payload}
      refute_receive {:running, _third}, 200
    end

    test "one that is still running when the extension is detached is stopped" do
      test_pid = self()

      Refresher.will(fn ->
        send(test_pid, {:running, self()})
        Process.sleep(:infinity)
      end)

      sync(%{"refresh" => true})
      assert_receive {:running, refresher}

      ref = Process.monitor(refresher)
      :ok = Extensions.detach("components")

      assert_receive {:DOWN, ^ref, :process, ^refresher, :killed}
    end
  end

  describe "the default client" do
    @describetag client: DefaultClient

    test "answers with no components when the device reports none" do
      attach()
      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => []}}
    end

    test "answers with what set_components/1 was given" do
      :ok = Components.set_components([@probe])
      attach()
      sync(%{"refresh" => true})

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [_probe]}}
    end
  end

  describe "a configured refresher" do
    @tag components: [refresher: Refresher]
    test "a module is called instead of the client" do
      attach()
      sync(%{"refresh" => true})

      assert_receive {:refresher_called, {:refresh, refresh: true}}
      refute_received {:refresher_called, {:client, _opts}}
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}
    end

    @tag components: [refresher: {Refresher, :listed, [:coordinator_0]}]
    test "an MFA is called with the options appended" do
      Refresher.will({:ok, [@mcu]})

      attach()
      sync()

      assert_receive {:refresher_called, {:listed, :coordinator_0, refresh: false}}
      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => [_mcu]}}
    end

    @tag components: [refresher: "MyApp.Refresher"]
    test "anything else is logged, and the client asked instead" do
      log =
        capture_log(fn ->
          attach()
          sync()

          assert_receive {:refresher_called, {:client, refresh: false}}
          assert_receive {:pushed, "extensions", "components:snapshot", _payload}
        end)

      assert log =~ "ignoring refresher"
    end
  end

  describe "readings" do
    setup do
      connected([@probe, @mcu])
    end

    test "are sent as the contract has them" do
      :ok =
        Components.report_readings(
          "zigbee",
          "00:12:4b:00:2a:3f:91:c7",
          %{temperature: -18.9, battery: 87},
          timestamp: ~U[2026-11-24 10:40:00Z]
        )

      assert_receive {:pushed, "extensions", "components:readings", payload}

      assert payload == %{
               "reports" => [
                 %{
                   "namespace" => "zigbee",
                   "serial" => "00:12:4b:00:2a:3f:91:c7",
                   "timestamp" => "2026-11-24T10:40:00Z",
                   "metrics" => %{"temperature" => -18.9, "battery" => 87}
                 }
               ]
             }
    end

    test "are stamped with the time they were reported" do
      :ok = Components.report_readings("mcu", "e6614c311b4a2c2f", %{"temperature" => 41})

      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => [report]}}
      assert {:ok, at, 0} = DateTime.from_iso8601(report["timestamp"])
      assert DateTime.diff(DateTime.utc_now(), at, :second) < 5
    end

    test "reported together go out in one message" do
      for n <- 1..5 do
        :ok = Components.report_readings("zigbee", "00:12:4b:00:2a:3f:91:c7", %{temperature: n})
      end

      # Sent once a second at most, so the first may go alone and the rest
      # wait for the next.
      reports = collect_readings(5)
      assert Enum.map(reports, & &1["metrics"]["temperature"]) == [1, 2, 3, 4, 5]
    end

    @tag max_readings: 200
    test "go out 60 reports a message" do
      :ok = :sys.suspend(Store)

      for n <- 1..130 do
        :ok = Components.report_readings("zigbee", "00:12:4b:00:2a:3f:91:c7", %{temperature: n})
      end

      :ok = :sys.resume(Store)

      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => first}}
      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => second}}
      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => third}}

      assert Enum.map([first, second, third], &length/1) == [60, 60, 10]
    end

    test "keep the first 20 names, as NervesHub does" do
      readings =
        Map.new(
          1..25,
          &{"reading_#{&1 |> Integer.to_string() |> String.pad_leading(2, "0")}", &1}
        )

      {result, log} =
        with_log(fn -> Components.report_readings("mcu", "e6614c311b4a2c2f", readings) end)

      assert result == :ok
      assert log =~ "more than 20 readings"

      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => [report]}}

      assert Map.keys(report["metrics"]) ==
               Enum.map(
                 1..20,
                 &"reading_#{&1 |> Integer.to_string() |> String.pad_leading(2, "0")}"
               )
    end

    test "drop a name or value NervesHub would refuse, and send the rest" do
      readings = %{"temperature" => 21.5, "Humidity" => 48, "battery" => "full", "on" => true}

      {result, log} =
        with_log(fn -> Components.report_readings("mcu", "e6614c311b4a2c2f", readings) end)

      assert result == :ok
      assert log =~ "dropped a reading"
      assert log =~ "is not a number"

      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => [report]}}
      assert report["metrics"] == %{"temperature" => 21.5}
    end

    test "with nothing left to report are refused" do
      {result, _log} =
        with_log(fn -> Components.report_readings("mcu", "e6614c311b4a2c2f", %{"Bad" => 1}) end)

      assert result == {:error, "no readings to report"}

      assert {:error, _reason} =
               Components.report_readings("mcu", "e6614c311b4a2c2f", temperature: 1)
    end

    test "for a component that isn't in the set are dropped and logged" do
      log =
        capture_log(fn ->
          :ok = Components.report_readings("zigbee", "not-paired", %{temperature: 1})
          _ = :sys.get_state(Store)
        end)

      assert log =~ "isn't in the component set"

      refute_receive {:pushed, "extensions", "components:readings", _payload},
                     @readings_interval_ms * 3
    end

    test "for a component NervesHub hasn't been sent wait for the snapshot that lists it" do
      # NervesHub ignores readings for a component it hasn't heard of, so they
      # would be lost if they went before the snapshot that lists it.
      :ok = Components.put_component(@lock)
      :ok = Components.report_readings("zwave", @lock.serial, %{battery: 90})

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => components}}
      assert Enum.any?(components, &(&1["namespace"] == "zwave"))

      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => [report]}}
      assert report["namespace"] == "zwave"
    end

    test "for a component that leaves the set before they go are forgotten" do
      :ok = Components.put_component(@lock)
      :ok = Components.report_readings("zwave", @lock.serial, %{battery: 90})
      :ok = Components.delete_component("zwave", @lock.serial)

      refute_receive {:pushed, "extensions", "components:readings", _payload},
                     @snapshot_delay_ms * 3
    end
  end

  describe "readings while detached" do
    @tag max_readings: 3
    test "are held, the oldest dropped past max_readings, and sent once NervesHub asks" do
      connected([@probe])

      :ok = Extensions.detach("components")
      assert_receive {:pushed, "extensions", "components:detached", _payload}

      log =
        capture_log(fn ->
          for n <- 1..5 do
            :ok =
              Components.report_readings("zigbee", "00:12:4b:00:2a:3f:91:c7", %{temperature: n})
          end

          _ = :sys.get_state(Store)
        end)

      assert log =~ "dropping the oldest"

      refute_receive {:pushed, "extensions", "components:readings", _payload},
                     @readings_interval_ms * 3

      attach()
      sync()
      assert_receive {:pushed, "extensions", "components:snapshot", _payload}

      assert_receive {:pushed, "extensions", "components:readings", %{"reports" => reports}}
      assert Enum.map(reports, & &1["metrics"]["temperature"]) == [3, 4, 5]
    end
  end

  describe "state" do
    setup do
      connected([@probe, @lock])
    end

    test "a change is sent as the contract has it" do
      :ok =
        Components.report_state("zwave", @lock.serial, :lock, :unlocked,
          detail: "by keypad, user 3",
          changed_at: ~U[2026-11-24 09:41:00Z]
        )

      assert_receive {:pushed, "extensions", "components:state", frame}

      assert frame == %{
               "namespace" => "zwave",
               "serial" => @lock.serial,
               "state" => "lock",
               "value" => "unlocked",
               "changed_at" => "2026-11-24T09:41:00Z",
               "detail" => "by keypad, user 3"
             }
    end

    test "changed_at defaults to now, and can be left out" do
      :ok = Components.report_state("zwave", @lock.serial, "lock", "locked")
      assert_receive {:pushed, "extensions", "components:state", %{"changed_at" => at}}
      assert {:ok, _at, 0} = DateTime.from_iso8601(at)

      :ok = Components.report_state("zwave", @lock.serial, "lock", "unlocked", changed_at: nil)
      assert_receive {:pushed, "extensions", "components:state", frame}
      refute Map.has_key?(frame, "changed_at")
      refute Map.has_key?(frame, "detail")
    end

    test "the value it already has isn't sent again" do
      :ok = Components.report_state("zwave", @lock.serial, :lock, :locked)
      assert_receive {:pushed, "extensions", "components:state", _frame}

      :ok = Components.report_state("zwave", @lock.serial, :lock, :locked)
      refute_receive {:pushed, "extensions", "components:state", _frame}, 100
    end

    test "is carried in every snapshot after it" do
      :ok = Components.report_state("zwave", @lock.serial, :lock, :jammed)
      assert_receive {:pushed, "extensions", "components:state", _frame}

      sync()

      assert_receive {:pushed, "extensions", "components:snapshot",
                      %{"components" => [_probe, lock]}}

      assert lock["state"] == %{"lock" => "jammed"}
    end

    test "survives a new set that doesn't mention it, and is replaced by one that does" do
      :ok = Components.report_state("zwave", @lock.serial, :lock, :jammed)

      :ok = Components.set_components([@probe, Map.put(@lock, :name, "Front door lock")])

      assert_receive {:pushed, "extensions", "components:snapshot",
                      %{"components" => [_probe, lock]}}

      assert lock["state"] == %{"lock" => "jammed"}

      :ok = Components.set_components([@probe, Map.put(@lock, :state, %{lock: :locked})])

      assert_receive {:pushed, "extensions", "components:snapshot",
                      %{"components" => [_probe, lock]}}

      assert lock["state"] == %{"lock" => "locked"}
    end

    test "is left out of the snapshot for a component nothing has said it of" do
      sync()

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => components}}
      assert Enum.all?(components, &(not Map.has_key?(&1, "state")))
    end

    test "for a component NervesHub hasn't been sent goes in the snapshot that lists it" do
      :ok = Components.put_component(@mcu)
      :ok = Components.report_state("mcu", @mcu.serial, :mode, :bootloader)

      assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => components}}

      assert %{"state" => %{"mode" => "bootloader"}} =
               Enum.find(components, &(&1["namespace"] == "mcu"))

      refute_received {:pushed, "extensions", "components:state", _frame}
    end

    test "for a component that isn't in the set is refused" do
      assert Components.report_state("zwave", "not-included", :lock, :locked) ==
               {:error, :unknown_component}
    end

    test "past 8 states on one component is refused" do
      for n <- 1..8 do
        assert :ok = Components.report_state("zwave", @lock.serial, "state_#{n}", "on")
      end

      assert Components.report_state("zwave", @lock.serial, :state_9, :on) ==
               {:error, :too_many_states}

      # A state it already has can still change.
      assert Components.report_state("zwave", @lock.serial, :state_1, :off) == :ok
    end

    test "a change NervesHub would refuse is refused here" do
      assert {:error, reason} = Components.report_state("zwave", @lock.serial, "Lock", "locked")
      assert reason =~ "state"

      assert {:error, reason} =
               Components.report_state("zwave", @lock.serial, :lock, String.duplicate("x", 65))

      assert reason =~ "longer than 64"

      assert {:error, _reason} = Components.report_state("zwave", @lock.serial, :lock, "")

      assert {:error, _reason} =
               Components.report_state("zwave", @lock.serial, :lock, :locked,
                 detail: String.duplicate("x", 256)
               )
    end
  end

  describe "without the store running" do
    test "nothing is recorded, and nothing raises" do
      :ok = stop_supervised(Store)

      assert Components.set_components([@probe]) == {:error, :not_running}
      assert Components.put_component(@probe) == {:error, :not_running}
      assert Components.delete_component("zigbee", "x") == {:error, :not_running}

      assert Components.report_readings("zigbee", "x", %{temperature: 1}) ==
               {:error, :not_running}

      assert Components.report_state("zigbee", "x", :lock, :locked) == {:error, :not_running}
      assert Components.components() == []
    end
  end

  test "components/0 shows the set as it would be sent" do
    :ok = Components.set_components([@lock])
    :ok = Components.report_state("zwave", @lock.serial, :lock, :locked)

    assert [%{"namespace" => "zwave", "state" => %{"lock" => "locked"}}] = Components.components()
  end

  defp attach() do
    _ = Extensions.offer(%{"components" => ["0.1.0"]})
    :ok = Extensions.attach("components")

    assert_receive {:pushed, "extensions", "components:attached", _payload}

    :ok
  end

  # Attached, with NervesHub holding `components`. The set is made after the
  # first sync is answered, so a snapshot debounced from before the attach
  # can't arrive in the middle of a test.
  defp connected(components) do
    attach()
    sync()
    assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => []}}

    :ok = Components.set_components(components)
    assert_receive {:pushed, "extensions", "components:snapshot", %{"components" => sent}}
    assert length(sent) == length(components)

    :ok
  end

  defp sync(payload \\ %{}) do
    send(Components, {:__extension_event__, "sync", payload})
  end

  defp collect_readings(count, acc \\ [])
  defp collect_readings(count, acc) when length(acc) >= count, do: acc

  defp collect_readings(count, acc) do
    assert_receive {:pushed, "extensions", "components:readings", %{"reports" => reports}}
    collect_readings(count, acc ++ reports)
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
