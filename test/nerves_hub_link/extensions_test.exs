# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ExtensionsTest.Reporter do
  @moduledoc """
  An extension that forwards everything it receives to the test process.
  """

  use NervesHubLink.Extensions, name: "reporter", version: "1.2.3"

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl NervesHubLink.Extensions
  def handle_event(event, payload, state) do
    send(NervesHubLink.ExtensionsTest.Reporter.Listener, {:extension_event, event, payload})
    {:noreply, state}
  end
end

defmodule NervesHubLink.ExtensionsTest.Broken do
  @moduledoc """
  An extension that refuses to start.
  """

  use NervesHubLink.Extensions, name: "broken", version: "0.0.1"

  @impl GenServer
  def init(_opts) do
    {:stop, :cannot_start}
  end

  @impl NervesHubLink.Extensions
  def handle_event(_event, _payload, state) do
    {:noreply, state}
  end
end

defmodule NervesHubLink.ExtensionsTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.ExtensionsTest.Broken
  alias NervesHubLink.ExtensionsTest.Reporter
  alias NervesHubLink.Support.SocketStub

  setup do
    # The extension routes events to a registered name so this test can receive
    # them from whichever process the extension GenServer runs in
    Process.register(self(), Reporter.Listener)

    previous = Application.get_env(:nerves_hub_link, :extension_modules)
    Application.put_env(:nerves_hub_link, :extension_modules, [Reporter, Broken])

    on_exit(fn ->
      if previous do
        Application.put_env(:nerves_hub_link, :extension_modules, previous)
      else
        Application.delete_env(:nerves_hub_link, :extension_modules)
      end
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)

    :ok
  end

  describe "list/0" do
    test "reports the configured extensions and their versions" do
      assert %{"reporter" => %{module: Reporter, version: "1.2.3"}} = Extensions.list()
    end

    test "ignores modules that aren't extensions" do
      Application.put_env(:nerves_hub_link, :extension_modules, [Reporter, NervesHubLink.Socket])

      extensions = Extensions.list()

      assert Map.keys(extensions) == ["reporter"]
    end
  end

  describe "offer/1" do
    test "offers an extension the platform has, at the version it named" do
      assert Extensions.offer(%{"reporter" => ["1.2.3"], "broken" => ["0.0.1"]}) == %{
               "reporter" => "1.2.3",
               "broken" => "0.0.1"
             }
    end

    test "picks the version both sides have out of several" do
      assert Extensions.offer(%{"reporter" => ["2.0.0", "1.2.3"]}) == %{"reporter" => "1.2.3"}
    end

    test "leaves out an extension the platform did not name" do
      # Either it does not implement it or an operator has switched it off.
      # Declaring it anyway would have this device offering to serve something
      # nothing will ever ask it for.
      assert Extensions.offer(%{"reporter" => ["1.2.3"]}) == %{"reporter" => "1.2.3"}
    end

    test "leaves out an extension whose versions do not overlap" do
      assert Extensions.offer(%{"reporter" => ["2.0.0"]}) == %{}
    end

    test "offers nothing when the platform has nothing" do
      assert Extensions.offer(%{}) == %{}
    end

    test "offers everything when no advertisement arrived" do
      # A NervesHub old enough not to advertise still serves the versions it
      # always did, so the answer is what this device implements rather than
      # nothing at all.
      assert Extensions.offer(nil) == %{"reporter" => "1.2.3", "broken" => "0.0.1"}
    end

    test "treats a payload it cannot read as no advertisement" do
      # A malformed message should not cost this device every extension it has.
      assert Extensions.offer("nonsense") == %{"reporter" => "1.2.3", "broken" => "0.0.1"}
    end
  end

  describe "attaching" do
    test "starts the extension and tells NervesHub" do
      :ok = Extensions.attach("reporter")

      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
      assert Process.whereis(Reporter)
    end

    test "an attached extension can push messages" do
      :ok = Extensions.attach("reporter")
      assert_receive {:pushed, "extensions", "reporter:attached", %{}}

      assert {:ok, _ref} = Reporter.push("report", %{"value" => 1})

      assert_receive {:pushed, "extensions", "reporter:report", %{"value" => 1}}
    end

    test "an unknown extension is reported as an error" do
      :ok = Extensions.attach("nope")

      assert_receive {:pushed, "extensions", "nope:error", %{reason: "unknown_extension"}}
    end

    test "an extension that fails to start is reported as an error" do
      :ok = Extensions.attach("broken")

      assert_receive {:pushed, "extensions", "broken:error", %{reason: "start_failure"}}
    end

    test "attaching everything attaches each known extension" do
      :ok = Extensions.attach(:all)

      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
      # `broken` can't start, so it reports an error rather than attaching
      assert_receive {:pushed, "extensions", "broken:error", %{reason: "start_failure"}}
    end

    test "an extension that fails to start doesn't stop the others attaching" do
      :ok = Extensions.attach(["broken", "reporter"])

      assert_receive {:pushed, "extensions", "broken:error", %{reason: "start_failure"}}
      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
    end
  end

  describe "detaching" do
    setup do
      :ok = Extensions.attach("reporter")
      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
      :ok
    end

    test "stops the extension and tells NervesHub" do
      :ok = Extensions.detach("reporter")

      assert_receive {:pushed, "extensions", "reporter:detached", %{}}
      refute Process.whereis(Reporter)
    end

    test "a detached extension can no longer push messages" do
      :ok = Extensions.detach("reporter")
      assert_receive {:pushed, "extensions", "reporter:detached", %{}}

      # Restarted by hand so `push/2` has a process to call from, standing in
      # for an extension that is still trying to send when it was detached
      _ = start_supervised!(Reporter)

      assert Reporter.push("report", %{}) == {:error, :detached}
      refute_receive {:pushed, "extensions", "reporter:report", %{}}, 100
    end

    test "detaching everything detaches attached extensions" do
      :ok = Extensions.detach(:all)

      assert_receive {:pushed, "extensions", "reporter:detached", %{}}
      refute Process.whereis(Reporter)
    end
  end

  describe "requests that don't name extensions" do
    test "attaching something that isn't a list of names is ignored" do
      assert Extensions.attach(%{"health" => "0.0.1"}) == :ok

      # Round-trip a call to be sure the request above was seen
      assert is_map(Extensions.list())
      assert Process.alive?(Process.whereis(Extensions))
      refute_receive {:pushed, "extensions", _event, _payload}, 100
    end

    test "detaching something that isn't a list of names leaves attachments alone" do
      :ok = Extensions.attach("reporter")
      assert_receive {:pushed, "extensions", "reporter:attached", %{}}

      assert Extensions.detach(%{"reporter" => "1.2.3"}) == :ok

      refute_receive {:pushed, "extensions", "reporter:detached", %{}}, 100
      assert {:ok, _ref} = Reporter.push("report", %{})
    end
  end

  describe "an extension that hasn't attached" do
    test "cannot push messages" do
      _ = start_supervised!(Reporter)

      assert Reporter.push("report", %{}) == {:error, :detached}
    end
  end

  describe "routing events from NervesHub" do
    test "an attach event attaches the named extensions" do
      :ok = Extensions.handle_event("attach", %{"extensions" => ["reporter"]})

      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
    end

    test "an attach event for a single extension name attaches it" do
      :ok = Extensions.handle_event("attach", %{"extensions" => "reporter"})

      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
    end

    test "an attach event for \"all\" attaches everything" do
      :ok = Extensions.handle_event("attach", %{"extensions" => "all"})

      assert_receive {:pushed, "extensions", "reporter:attached", %{}}
    end

    test "a detach event detaches the named extensions" do
      :ok = Extensions.attach("reporter")
      assert_receive {:pushed, "extensions", "reporter:attached", %{}}

      :ok = Extensions.handle_event("detach", %{"extensions" => ["reporter"]})

      assert_receive {:pushed, "extensions", "reporter:detached", %{}}
    end

    test "an attach event without extensions is ignored" do
      :ok = Extensions.handle_event("attach", %{})

      refute_receive {:pushed, "extensions", "reporter:attached", %{}}, 100
      assert Process.alive?(Process.whereis(Extensions))
    end

    test "a namespaced event is routed to its extension" do
      :ok = Extensions.attach("reporter")
      assert_receive {:pushed, "extensions", "reporter:attached", %{}}

      :ok = Extensions.handle_event("reporter:check", %{"now" => true})

      assert_receive {:extension_event, "check", %{"now" => true}}
    end

    test "an event for an unknown extension is ignored" do
      :ok = Extensions.handle_event("nope:check", %{})

      assert Process.alive?(Process.whereis(Extensions))
    end
  end
end
