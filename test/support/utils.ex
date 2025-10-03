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

  @spec supervise_with_port(plug :: module()) :: {:ok, pid, integer()}
  def supervise_plug(plug) do
    supervise_with_port(fn port ->
      {Plug.Cowboy, scheme: :http, plug: plug, options: [port: port]}
    end)
  end

  @spec supervise_with_port(function(), integer() | nil) :: {:ok, pid, integer()}
  def supervise_with_port(child_spec_fn, port \\ nil) do
    port =
      if port do
        port + 1
      else
        unique_port_number()
      end

    child_spec = child_spec_fn.(port)

    case ExUnit.Callbacks.start_supervised(child_spec) do
      {:ok, plug} ->
        {:ok, plug, port}

      {:error, :eaddrinuse} ->
        supervise_with_port(child_spec_fn, port)
    end
  end
end
