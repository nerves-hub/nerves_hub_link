# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Refresher do
  @moduledoc """
  Behaviour for checking on the device's components when NervesHub asks.

  Someone looking at a device in the NervesHub web UI can ask it to look at its
  components again. The device is sent `components:sync` with
  `{"refresh": true}`, and a device that can check on its components, such as
  by pinging each Zigbee node, should do so before it answers rather than send
  what it last knew.

  A device without a refresher answers straight away with what it knows, which
  is also a correct answer.

      defmodule MyApp.ComponentRefresher do
        @behaviour NervesHubLink.Extensions.Components.Refresher

        @impl true
        def refresh() do
          {:ok, Enum.map(MyApp.Zigbee.ping_all(), &MyApp.Zigbee.to_component/1)}
        end
      end

      config :nerves_hub_link,
        components: [refresher: MyApp.ComponentRefresher]

  ## What to return

    * `{:ok, components}` - the device's whole component set, as
      `NervesHubLink.Extensions.Components.set_components/1` takes it. It
      replaces what the device had.
    * `:ok` - the set is up to date, because nothing changed or because the
      refresher updated it itself with
      `NervesHubLink.Extensions.Components.set_components/1` or
      `NervesHubLink.Extensions.Components.put_component/1`.
    * `{:error, reason}` - the check failed. It is logged, and the device
      answers with what it already knew.

  ## How long it may take

  `refresh/0` runs in a process of its own, so a slow check holds up nothing
  else. NervesHub is answered when it returns, or after
  `refresh_timeout_seconds` (30 by default), whichever is first. Past the
  timeout the refresher is stopped and the device answers with what it knew.

      config :nerves_hub_link,
        components: [refresher: MyApp.ComponentRefresher, refresh_timeout_seconds: 60]

  A refresher that raises or exits is logged, and the device answers with what
  it knew.
  """

  @doc """
  Check on the device's components, and return them or say they are current.
  """
  @callback refresh() ::
              :ok
              | {:ok, [NervesHubLink.Extensions.Components.Component.input()]}
              | {:error, reason :: term()}
end
