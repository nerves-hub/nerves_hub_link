# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.Utils do
  @moduledoc false

  @spec unique_port_number() :: integer()
  def unique_port_number() do
    System.unique_integer([:positive, :monotonic]) + 6000
  end

  @spec supervise_plug(plug :: module(), opts :: keyword()) :: {:ok, pid, integer()}
  def supervise_plug(plug, opts \\ []) do
    server =
      {Bandit, scheme: :http, plug: {plug, opts}, ip: :loopback, port: 0}
      |> ExUnit.Callbacks.start_supervised!()

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, server, port}
  end
end
