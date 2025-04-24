# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.Utils do
  @moduledoc false

  @port_registry_name NervesHubLink.Support.Utils.UniquePortNumber

  @spec start_registry() :: {:ok, pid()}
  def start_registry() do
    {:ok, _} = Registry.start_link(keys: :unique, name: NervesHubLink.Registry)
    Agent.start_link(fn -> 6000 end, name: @port_registry_name)
  end

  @spec unique_port_number() :: integer()
  def unique_port_number() do
    Agent.get_and_update(@port_registry_name, &{&1, &1 + 1})
  end

  @spec supervise_with_port(function(), integer() | nil) :: {:ok, pid, integer()}
  def supervise_with_port(child_spec_fn, port \\ nil) do
    port = port || unique_port_number()
    child_spec = child_spec_fn.(port)

    case ExUnit.Callbacks.start_supervised(child_spec) do
      {:ok, plug} ->
        {:ok, plug, port}

      {:error, _} ->
        port = unique_port_number()
        supervise_with_port(child_spec_fn, port)
    end
  end
end
