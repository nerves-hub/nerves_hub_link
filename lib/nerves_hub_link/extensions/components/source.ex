# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Source do
  @moduledoc """
  A runtime source of component topology.

  The fixed parts of a device's topology belong in config (see
  `NervesHubLink.Extensions.Components`), but some topology only exists at
  runtime: a Z-Wave controller only knows its paired devices once the network
  is up, a modular device only knows which expansion boards are present after
  probing them.

  A source is a module that answers for that part. It is consulted every time
  a topology report is built, so whatever it returns reflects the state of the
  world at that moment. Both callbacks are optional; implement the one(s) that
  apply.

      defmodule MyApp.ZWaveTopology do
        @behaviour NervesHubLink.Extensions.Components.Source

        @impl NervesHubLink.Extensions.Components.Source
        def networks() do
          [
            %{
              identifier: "zwave",
              label: "Z-Wave",
              metrics: ["zwave_rssi"],
              peers: Enum.map(MyApp.ZWave.nodes(), &to_peer/1)
            }
          ]
        end
      end

  Register it in config:

      config :nerves_hub_link,
        components: [sources: [MyApp.ZWaveTopology]]

  When a source's answer changes (a peer joined, a board was hot-plugged),
  call `NervesHubLink.Extensions.Components.report_topology/0` to send a fresh
  report to NervesHub; nothing polls the sources on its own.

  The entry shapes are the same maps the static config takes — see
  `NervesHubLink.Extensions.Components` for the full description.
  """

  @doc """
  Assemblies (and their components) this source contributes.
  """
  @callback assemblies() :: [map()]

  @doc """
  Networks (and their peers) this source contributes.
  """
  @callback networks() :: [map()]

  @optional_callbacks assemblies: 0, networks: 0
end
