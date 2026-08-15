# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ExternalIdentityTest.IrohProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity() do
    {:ok,
     %{
       service: :iroh,
       identifier: "e13b8a4c9f2d",
       details: %{"relay_url" => "https://iroh.nervescloud.com"}
     }}
  end
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.NetBirdProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity() do
    {:ok, %{service: "netbird", identifier: "peer-key-9000"}}
  end
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.StringKeyedProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity() do
    {:ok,
     %{"service" => "tailscale", "identifier" => "nodekey-abc", "details" => %{"os" => "linux"}}}
  end
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.ConsoleInstanceProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity() do
    {:ok, %{service: "iroh", instance: "iroh_console", identifier: "console-key"}}
  end
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.AtomInstanceProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity() do
    {:ok, %{service: :iroh, instance: :iroh_console, identifier: "atom-instance-key"}}
  end
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.BlankInstanceProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity() do
    {:ok, %{service: "iroh", instance: "", identifier: "blank-instance-key"}}
  end
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.UnavailableProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity(), do: :unavailable
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.ErroringProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity(), do: {:error, :endpoint_not_started}
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.RaisingProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity(), do: raise("the endpoint is on fire")
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest.ConfusedProvider do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

  @impl NervesHubLink.Extensions.ExternalIdentity.Provider
  def identity(), do: {:ok, %{service: "iroh"}}
end

defmodule NervesHubLink.Extensions.ExternalIdentityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias NervesHubLink.Extensions.ExternalIdentity
  alias NervesHubLink.Extensions.ExternalIdentityTest.AtomInstanceProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.BlankInstanceProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.ConfusedProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.ConsoleInstanceProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.ErroringProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.IrohProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.NetBirdProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.RaisingProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.StringKeyedProvider
  alias NervesHubLink.Extensions.ExternalIdentityTest.UnavailableProvider

  setup do
    previous = Application.get_env(:nerves_hub_link, :external_identity)

    on_exit(fn ->
      if previous do
        Application.put_env(:nerves_hub_link, :external_identity, previous)
      else
        Application.delete_env(:nerves_hub_link, :external_identity)
      end
    end)

    :ok
  end

  defp put_providers(providers) do
    Application.put_env(:nerves_hub_link, :external_identity, providers: providers)
  end

  describe "identities/0" do
    test "reports nothing when no providers are configured" do
      assert ExternalIdentity.identities() == []
    end

    test "collects one identity per provider" do
      put_providers([IrohProvider, NetBirdProvider])

      assert [iroh, netbird] = ExternalIdentity.identities()
      assert iroh.service == "iroh"
      assert iroh.identifier == "e13b8a4c9f2d"
      assert iroh.details == %{"relay_url" => "https://iroh.nervescloud.com"}
      assert netbird.service == "netbird"
      assert netbird.identifier == "peer-key-9000"
    end

    test "an atom service is normalized to a string for the wire" do
      put_providers([IrohProvider])

      assert [%{service: "iroh"}] = ExternalIdentity.identities()
    end

    test "details defaults to an empty map when a provider omits it" do
      put_providers([NetBirdProvider])

      assert [%{details: %{}}] = ExternalIdentity.identities()
    end

    test "a string-keyed identity is accepted too" do
      # Providers are written by hand, and losing an identity over an atom
      # versus string mistake would be a miserable thing to debug.
      put_providers([StringKeyedProvider])

      assert [%{service: "tailscale", identifier: "nodekey-abc", details: %{"os" => "linux"}}] =
               ExternalIdentity.identities()
    end

    test "an instance is passed through when a provider names one" do
      put_providers([ConsoleInstanceProvider])

      assert [%{instance: "iroh_console"}] = ExternalIdentity.identities()
    end

    test "an atom instance is stringified for the wire" do
      put_providers([AtomInstanceProvider])

      assert [%{instance: "iroh_console"}] = ExternalIdentity.identities()
    end

    test "no instance key is sent when a provider doesn't name one" do
      # Leaving it out lets NervesHub apply its own default rather than this
      # library guessing at the name for it.
      put_providers([IrohProvider])

      assert [identity] = ExternalIdentity.identities()
      refute Map.has_key?(identity, :instance)
    end

    test "a blank or unusable instance is left out rather than sent" do
      put_providers([BlankInstanceProvider])

      assert [identity] = ExternalIdentity.identities()
      refute Map.has_key?(identity, :instance)
    end

    test "a single provider can be configured without a list" do
      Application.put_env(:nerves_hub_link, :external_identity, providers: IrohProvider)

      assert [%{service: "iroh"}] = ExternalIdentity.identities()
    end
  end

  describe "a provider that can't report" do
    test ":unavailable is quiet, because it happens on every reconnect" do
      put_providers([UnavailableProvider])

      log = capture_log(fn -> assert ExternalIdentity.identities() == [] end)

      refute log =~ "[warning]"
    end

    test "an error is reported and the provider skipped" do
      put_providers([ErroringProvider])

      log = capture_log(fn -> assert ExternalIdentity.identities() == [] end)

      assert log =~ "failed to resolve an identity"
      assert log =~ "endpoint_not_started"
    end

    test "a provider that raises does not take the extension with it" do
      put_providers([RaisingProvider])

      log = capture_log(fn -> assert ExternalIdentity.identities() == [] end)

      assert log =~ "the endpoint is on fire"
    end

    test "an identity missing its identifier is skipped and named" do
      put_providers([ConfusedProvider])

      log = capture_log(fn -> assert ExternalIdentity.identities() == [] end)

      assert log =~ "without :service and :identifier"
      assert log =~ "ConfusedProvider"
    end

    test "one broken provider does not cost the others their identities" do
      put_providers([RaisingProvider, IrohProvider, ErroringProvider, NetBirdProvider])

      {identities, _log} = with_log(fn -> ExternalIdentity.identities() end)

      assert [%{service: "iroh"}, %{service: "netbird"}] = identities
    end
  end

  describe "reporting to NervesHub" do
    setup do
      _ = start_supervised!({NervesHubLink.Support.SocketStub, self()})
      _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
      _ = start_supervised!(NervesHubLink.Extensions)

      :ok = NervesHubLink.Extensions.attach(["external_identity"])

      # attach/1 is a cast, so wait for the extension to be running before
      # anything calls into it.
      wait_for_process(ExternalIdentity)

      :ok
    end

    test "answers a request from the server with the collected identities" do
      put_providers([IrohProvider])

      send(ExternalIdentity, {:__extension_event__, "request", %{}})

      assert_receive {:pushed, "extensions", "external_identity:report", payload}, 1_000
      assert [%{service: "iroh", identifier: "e13b8a4c9f2d"}] = payload.identities
    end

    test "send_report/0 announces without being asked" do
      put_providers([NetBirdProvider])

      assert ExternalIdentity.send_report() == :ok

      assert_receive {:pushed, "extensions", "external_identity:report", payload}, 1_000
      assert [%{service: "netbird"}] = payload.identities
    end

    test "being asked with no providers configured says so out loud" do
      # The server only asks when an operator switched this on, so an empty
      # provider list almost certainly means a half-finished setup.
      log =
        capture_log(fn ->
          assert ExternalIdentity.send_report() == :ok
        end)

      assert log =~ "no providers are configured"
      assert_receive {:pushed, "extensions", "external_identity:report", %{identities: []}}, 1_000
    end
  end

  defp wait_for_process(name, attempts \\ 50) do
    cond do
      Process.whereis(name) ->
        :ok

      attempts == 0 ->
        flunk("#{inspect(name)} never started")

      true ->
        Process.sleep(10)
        wait_for_process(name, attempts - 1)
    end
  end
end
