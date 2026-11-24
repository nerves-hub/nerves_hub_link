# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.StateChange do
  @moduledoc false

  # One `components:state` frame: a component's state taking a new value.

  alias NervesHubLink.Extensions.Components.Check
  alias NervesHubLink.Extensions.Components.Component

  @type t() :: %{String.t() => String.t()}

  @doc """
  Check a state change and write it as a frame.

  `changed_at` defaults to now. Passing `changed_at: nil` leaves it out, for a
  device without a clock it can trust, and NervesHub stamps the change with the
  time it arrived instead.
  """
  @spec new(term(), term(), term(), term(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(namespace, serial, state, value, opts) do
    with {:ok, namespace} <- Check.namespace(namespace),
         {:ok, serial} <- Check.required(serial, "serial"),
         {:ok, state} <- Check.name(state, "state"),
         {:ok, value} <- Component.state_value(value),
         {:ok, detail} <- Check.optional(Keyword.get(opts, :detail), "detail"),
         {:ok, changed_at} <- changed_at(Keyword.get_lazy(opts, :changed_at, &Check.now/0)) do
      %{"namespace" => namespace, "serial" => serial, "state" => state, "value" => value}
      |> put_present("detail", detail)
      |> put_present("changed_at", changed_at)
      |> then(&{:ok, &1})
    end
  end

  defp changed_at(nil), do: {:ok, nil}
  defp changed_at(at), do: Check.timestamp(at, "changed_at")

  defp put_present(frame, _key, nil), do: frame
  defp put_present(frame, key, value), do: Map.put(frame, key, value)
end
