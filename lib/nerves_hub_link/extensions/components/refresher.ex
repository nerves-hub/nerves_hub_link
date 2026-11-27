# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Refresher do
  @moduledoc """
  Behaviour for answering NervesHub when it asks for the device's components.

  NervesHub sends `components:sync` every time the device connects, and again
  when someone asks from the web UI for the device to look at its components
  again (`{"refresh": true}`). The device answers each with its whole
  component set, and it gets that set from its refresher.

  ## Choosing the refresher

  By default the refresher is your `NervesHubLink.Client`, and
  `c:NervesHubLink.Client.components_sync/1` is called. Most devices need
  nothing else:

      defmodule MyApp.NervesHubLinkClient do
        use NervesHubLink.Client

        @impl NervesHubLink.Client
        def components_sync(refresh: true) do
          {:ok, Enum.map(MyApp.Zigbee.ping_all(), &MyApp.Zigbee.to_component/1)}
        end

        def components_sync(refresh: false) do
          {:ok, Enum.map(MyApp.Zigbee.known_nodes(), &MyApp.Zigbee.to_component/1)}
        end
      end

  To answer from somewhere else, set `refresher` to a module implementing this
  behaviour:

      config :nerves_hub_link,
        components: [refresher: MyApp.ComponentRefresher]

  or to an MFA, which is called with the options appended to its arguments:

      config :nerves_hub_link,
        components: [refresher: {MyApp.Zigbee, :components, [:coordinator_0]}]

      # Called as MyApp.Zigbee.components(:coordinator_0, refresh: false)

  ## What to return

    * `{:ok, components}` - the device's whole component set, as
      `NervesHubLink.Extensions.Components.set_components/1` takes it. It
      replaces what the device had.
    * `:ok` - answer with the set as it stands: whatever was last given to
      `NervesHubLink.Extensions.Components.set_components/1` or
      `NervesHubLink.Extensions.Components.put_component/1`, and empty if
      nothing was. This is what the default client returns, so a device that
      reports nothing answers that it has no components.
    * `{:error, reason}` - the check failed. It is logged, and answered as
      `:ok` would be.

  Returning `:ok` is how an application that pushes changes with
  `set_components/1` as they happen says it has nothing to add.

  ## How long it may take

  It runs in a process of its own, so a slow check holds up nothing else.
  NervesHub is answered when it returns, or after `refresh_timeout_seconds`
  (30 by default), whichever is first. Past the timeout it is stopped and the
  device answers with the set as it stands.

      config :nerves_hub_link,
        components: [refresh_timeout_seconds: 60]

  A refresher that raises or exits is logged, and the device answers with the
  set as it stands.
  """

  @doc """
  Return the device's components, or say the set as it stands is current.

  `opts[:refresh]` is `true` when someone asked the device to look at its
  components again, and the device should check on them before answering if it
  can.
  """
  @callback refresh(opts :: [refresh: boolean()]) ::
              NervesHubLink.Client.components_sync_response()
end
