# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Reading do
  @moduledoc false

  # One report in a `components:readings` message: what one component measured
  # at one moment.

  alias NervesHubLink.Extensions.Components.Check

  require Logger

  # What NervesHub keeps of one report. It keeps the first 20 names in sorted
  # order, so the same are dropped here and the device logs which.
  @max_metrics 20

  @type t() :: %{String.t() => String.t() | %{String.t() => number()}}

  @doc """
  Check a component's readings and write them as one report.

  A metric whose name NervesHub would refuse, or whose value isn't a number, is
  dropped with a warning. A report left with nothing to say is an error.
  """
  @spec new(term(), term(), map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(namespace, serial, metrics, opts) do
    with {:ok, namespace} <- Check.namespace(namespace),
         {:ok, serial} <- Check.required(serial, "serial"),
         {:ok, timestamp} <-
           Check.timestamp(Keyword.get_lazy(opts, :timestamp, &Check.now/0), "timestamp"),
         {:ok, metrics} <- metrics(metrics, {namespace, serial}) do
      {:ok,
       %{
         "namespace" => namespace,
         "serial" => serial,
         "timestamp" => timestamp,
         "metrics" => metrics
       }}
    end
  end

  defp metrics(metrics, key) when is_map(metrics) do
    checked =
      metrics
      |> Enum.flat_map(fn {name, value} ->
        case Check.name(name, "reading") do
          {:ok, name} when is_number(value) ->
            [{name, value}]

          {:ok, name} ->
            warn(key, "dropped reading #{name}: #{inspect(value, limit: 5)} is not a number")
            []

          {:error, reason} ->
            warn(key, "dropped a reading: #{reason}")
            []
        end
      end)
      |> Enum.sort()

    if length(checked) > @max_metrics do
      warn(
        key,
        "reported more than #{@max_metrics} readings at once; sending the first #{@max_metrics} by name"
      )
    end

    case Enum.take(checked, @max_metrics) do
      [] -> {:error, "no readings to report"}
      kept -> {:ok, Map.new(kept)}
    end
  end

  defp metrics(metrics, _key),
    do: {:error, "readings must be a map of name to number, got #{inspect(metrics, limit: 5)}"}

  defp warn({namespace, serial}, message) do
    Logger.warning("[NervesHubLink.Extensions.Components] #{namespace} #{serial} #{message}")
  end
end
