# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ExternalIdentity.Provider do
  @moduledoc """
  Behaviour for reporting an identity this device holds on another network.

  There is no default implementation, and there cannot be one: NervesHubLink has
  no way to know that your device is also an iroh endpoint or a NetBird peer.
  The library that owns that identity does, so it — or your application — supplies
  a provider.

  One provider reports one service. A device on both iroh and NetBird configures
  two.

  ## Writing one

      defmodule MyApp.IrohIdentity do
        @behaviour NervesHubLink.Extensions.ExternalIdentity.Provider

        @impl true
        def identity() do
          case IrohConsole.Server.addr() do
            {:ok, addr} ->
              {:ok,
               %{
                 service: "iroh",
                 identifier: to_string(addr.id),
                 details: %{"ticket" => IrohConsole.NervesHub.ticket()}
               }}

            {:error, :not_running} ->
              :unavailable
          end
        end
      end

  And then:

      config :nerves_hub_link,
        external_identity: [providers: [MyApp.IrohIdentity]]

  ## Returning `:unavailable` rather than an error

  The two failure returns are logged differently, and the distinction is worth
  keeping. `:unavailable` means "nothing to report right now" — the endpoint
  hasn't started, or this unit simply isn't on that network — and is logged at
  debug. `{:error, reason}` means something is actually wrong and is logged as a
  warning.

  Devices reconnect often. A unit that legitimately has no iroh identity should
  not produce a warning on every connect, or the warnings stop meaning anything.

  ## What `identifier` should be

  The value the device cryptographically proves possession of: its iroh endpoint
  id, or its WireGuard/NetBird/Tailscale public key. Handles that a control plane
  assigns and can reassign — a NetBird peer id, an overlay IP — belong in
  `details`.

  Never put a secret in `details`. This is an identity record, and it is shown
  in the NervesHub UI to anyone who can view the device.
  """

  @typedoc """
  A single identity.

  `service` must be one your NervesHub knows about — currently `iroh`,
  `netbird`, `tailscale` or `wireguard`. Anything else is discarded server-side,
  which is deliberate: an unknown service must not cost a device its other
  identities.

  `instance` names *which* endpoint of that service this is, and only matters
  when a device runs more than one. Two iroh endpoints — a console and an
  application — are both `iroh`, and are told apart by their instance. Omit it
  and NervesHub treats this as the service's only endpoint.

  Pick something stable. NervesHub keys the identity on it, so an instance that
  changes between reports produces a second record rather than updating the
  first. The name of the library or feature that owns the endpoint works well;
  anything derived from the key itself does not.

  `details` is free-form and must survive being encoded for the wire. Keep it
  small; NervesHub rejects a `details` payload over 4KB once encoded.
  """
  @type identity() :: %{
          required(:service) => String.t() | atom(),
          required(:identifier) => String.t(),
          optional(:instance) => String.t() | atom(),
          optional(:details) => map()
        }

  @typedoc "Supported responses from `c:identity/0`"
  @type response() ::
          {:ok, identity()}
          | :unavailable
          | {:error, reason :: term()}

  @doc """
  Report this device's identity for one service.

  Called when NervesHub asks, which is once per connection, so it is fine for
  this to read from a running process. It should not block for long.
  """
  @callback identity() :: response()
end
