# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Component do
  @moduledoc """
  One component, checked and written the way `components:snapshot` carries it.

  Your application describes a component as a map, with atom or string keys:

      %{
        namespace: "zigbee",
        vendor: "1286",
        model: "SNZB-02D",
        serial: "00:12:4b:00:2a:3f:91:c7",
        name: "Freezer probe A",
        vendor_name: "Sonoff",
        versions: %{firmware: "2.1.0"},
        last_seen_at: ~U[2026-11-24 10:42:11Z]
      }

  `namespace`, `vendor`, `model` and `serial` are required. Everything else is
  optional:

    * `name`, `vendor_name`, `model_name`, `hardware_revision`, `address` -
      strings. An empty one is left out.
    * `versions` - what the component holds and which version of each, as
      `%{key => version}`: `%{firmware: "2.2.1", keypad_config: "7"}`. Use
      `firmware` for its firmware, and a name of your own for anything else
      it holds, such as a configuration or a model. Report every one: a
      version NervesHub can't see is an update it can't confirm. Versions are
      strings, compared exactly; a `Version` is written as one.
    * `reachable` - `false` when the device has the component but couldn't
      reach it the last time it tried. Leave it out, or pass `true`, otherwise.
    * `last_seen_at` - a `DateTime`, or an ISO 8601 string with an offset. Leave
      it out on a device without a clock it can trust.
    * `state` - the component's current state, as `%{state => value}`. See
      `NervesHubLink.Extensions.Components.report_state/5`.

  See `NervesHubLink.Extensions.Components` for what to put in `vendor`,
  `model` and `serial` for each namespace.

  ## What happens to a bad entry

  NervesHub rejects a whole snapshot when any entry in it is bad, and a
  rejected snapshot changes nothing. That would hide a component you got wrong
  behind every one you got right, so each entry is checked here first.

  An entry missing a required field, or with one NervesHub won't accept, is
  left out of the snapshot and logged. An optional field it won't accept is
  dropped from the entry and logged, and the rest of the entry is sent: a
  component is better listed without its name than not listed at all, which
  NervesHub would show as Missing.
  """

  alias NervesHubLink.Extensions.Components.Check

  require Logger

  @max_states 8
  @max_versions 16

  @optional ~w(name vendor_name model_name hardware_revision address)a

  @typedoc """
  A component as your application describes it. Keys may be atoms or strings.
  """
  @type input() :: map()

  @typedoc """
  A component as the wire carries it: string keys, with absent fields left out.
  """
  @type t() :: %{String.t() => String.t() | boolean() | %{String.t() => String.t()}}

  @typedoc "Which component this is on the device: its namespace and serial."
  @type key() :: {namespace :: String.t(), serial :: String.t()}

  @doc """
  Check a component and write it for the wire.

  Returns `{:error, reason}` when a required field is missing or one NervesHub
  would refuse. An optional field it would refuse is dropped, with a warning.

  ## Examples

      iex> NervesHubLink.Extensions.Components.Component.new(%{
      ...>   namespace: "mcu",
      ...>   vendor: "raspberrypi",
      ...>   model: "rp2350",
      ...>   serial: "e6614c311b4a2c2f",
      ...>   versions: %{firmware: "1.4.2"}
      ...> })
      {:ok,
       %{
         "namespace" => "mcu",
         "vendor" => "raspberrypi",
         "model" => "rp2350",
         "serial" => "e6614c311b4a2c2f",
         "versions" => %{"firmware" => "1.4.2"}
       }}

      iex> NervesHubLink.Extensions.Components.Component.new(%{namespace: "mcu", vendor: "st"})
      {:error, "model is missing"}

  """
  @spec new(input()) :: {:ok, t()} | {:error, String.t()}
  def new(component) when is_map(component) do
    with {:ok, namespace} <- Check.namespace(field(component, :namespace)),
         {:ok, vendor} <- Check.required(field(component, :vendor), "vendor"),
         {:ok, model} <- Check.required(field(component, :model), "model"),
         {:ok, serial} <- Check.required(field(component, :serial), "serial") do
      key = {namespace, serial}

      entry =
        %{"namespace" => namespace, "vendor" => vendor, "model" => model, "serial" => serial}
        |> put_optional_strings(component, key)
        |> put_versions(field(component, :versions), key)
        |> put_reachable(field(component, :reachable), key)
        |> put_last_seen_at(field(component, :last_seen_at), key)
        |> put_state(field(component, :state), key)

      {:ok, entry}
    end
  end

  def new(component),
    do: {:error, "a component must be a map, got #{inspect(component, limit: 5)}"}

  @doc "The component's namespace and serial, which identify it on the device."
  @spec key(t()) :: key()
  def key(%{"namespace" => namespace, "serial" => serial}), do: {namespace, serial}

  @doc """
  Check a component's state, `%{state => value}`, and write it for the wire.

  A state name, or a value, that NervesHub would refuse is dropped with a
  warning. Past #{@max_states} states the rest are dropped, which is all
  NervesHub keeps.
  """
  @spec state(map(), key()) :: %{String.t() => String.t()}
  def state(state, key) when is_map(state) do
    checked =
      Enum.flat_map(state, fn {name, value} ->
        with {:ok, name} <- Check.name(name, "state"),
             {:ok, value} <- state_value(value) do
          [{name, value}]
        else
          {:error, reason} ->
            warn(key, "dropped a state: #{reason}")
            []
        end
      end)
      |> Enum.sort()

    if length(checked) > @max_states do
      warn(key, "has more than #{@max_states} states; sending the first #{@max_states} by name")
    end

    checked |> Enum.take(@max_states) |> Map.new()
  end

  @doc """
  Check a component's versions, `%{key => version}`, and write them for the
  wire.

  A key or a version NervesHub would refuse is dropped with a warning, and an
  empty version is left out. Past #{@max_versions} the rest are dropped,
  keeping `firmware` and then the first by key, since NervesHub would refuse
  the whole snapshot.
  """
  @spec versions(map(), key()) :: %{String.t() => String.t()}
  def versions(versions, key) when is_map(versions) do
    checked =
      versions
      |> Enum.flat_map(fn {name, version} ->
        with {:ok, name} <- Check.version_key(name),
             {:ok, version} when is_binary(version) <- version_string(version, name) do
          [{name, version}]
        else
          {:ok, nil} ->
            []

          {:error, reason} ->
            warn(key, "dropped a version: #{reason}")
            []
        end
      end)
      |> Enum.sort_by(fn {name, _version} -> {name != "firmware", name} end)

    if length(checked) > @max_versions do
      warn(key, "has more than #{@max_versions} versions; sending firmware and the first by key")
    end

    checked |> Enum.take(@max_versions) |> Map.new()
  end

  @doc false
  @spec max_versions() :: 16
  def max_versions(), do: @max_versions

  defp version_string(%Version{} = version, name),
    do: Check.optional(to_string(version), "version #{name}")

  defp version_string(version, name), do: Check.optional(version, "version #{name}")

  @doc false
  @spec max_states() :: 8
  def max_states(), do: @max_states

  @doc false
  # A state value: a non-empty string of at most 64 characters. An atom is
  # accepted, since `:locked` is how Elixir code tends to hold one.
  @spec state_value(term()) :: {:ok, String.t()} | {:error, String.t()}
  def state_value(value) when is_atom(value) and value not in [nil, true, false],
    do: state_value(Atom.to_string(value))

  def state_value(value), do: Check.required(value, "state value", Check.max_state_value_length())

  # Atom keys are what Elixir code writes; string keys are what a component
  # read from JSON or a database has. An atom key wins when a map has both.
  defp field(component, key) do
    case Map.fetch(component, key) do
      {:ok, value} -> value
      :error -> Map.get(component, Atom.to_string(key))
    end
  end

  defp put_optional_strings(entry, component, key) do
    Enum.reduce(@optional, entry, fn field, entry ->
      name = Atom.to_string(field)

      case Check.optional(field(component, field), name) do
        {:ok, nil} ->
          entry

        {:ok, value} ->
          Map.put(entry, name, value)

        {:error, reason} ->
          warn(key, "dropped #{name}: #{reason}")
          entry
      end
    end)
  end

  defp put_reachable(entry, nil, _key), do: entry

  defp put_reachable(entry, reachable, _key) when is_boolean(reachable),
    do: Map.put(entry, "reachable", reachable)

  defp put_reachable(entry, reachable, key) do
    warn(key, "dropped reachable: must be true or false, got #{inspect(reachable, limit: 5)}")
    entry
  end

  defp put_last_seen_at(entry, nil, _key), do: entry

  defp put_last_seen_at(entry, at, key) do
    case Check.timestamp(at, "last_seen_at") do
      {:ok, at} ->
        Map.put(entry, "last_seen_at", at)

      {:error, reason} ->
        warn(key, "dropped last_seen_at: #{reason}")
        entry
    end
  end

  # Left out when there are none, which NervesHub reads the same as an empty
  # map: the component holds nothing it reports a version for.
  defp put_versions(entry, nil, _key), do: entry

  defp put_versions(entry, versions, key) when is_map(versions) do
    case versions(versions, key) do
      checked when map_size(checked) == 0 -> entry
      checked -> Map.put(entry, "versions", checked)
    end
  end

  defp put_versions(entry, versions, key) do
    warn(
      key,
      "dropped versions: must be a map of key to version, got #{inspect(versions, limit: 5)}"
    )

    entry
  end

  # Left out to say nothing about state, which is not the same as an empty map:
  # `%{}` tells NervesHub the component has no state at all.
  defp put_state(entry, nil, _key), do: entry

  defp put_state(entry, state, key) when is_map(state),
    do: Map.put(entry, "state", state(state, key))

  defp put_state(entry, state, key) do
    warn(key, "dropped state: must be a map of state to value, got #{inspect(state, limit: 5)}")
    entry
  end

  defp warn({namespace, serial}, message) do
    Logger.warning("[NervesHubLink.Extensions.Components] #{namespace} #{serial} #{message}")
  end
end
