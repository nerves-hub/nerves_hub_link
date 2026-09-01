# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Topology do
  @moduledoc """
  Builds the component topology from config and runtime sources.

  The topology is assembled fresh on every call so runtime sources always
  answer for the current state of the device. Entries are normalized to
  string-keyed maps for the wire; action and mode handlers are kept out of the
  report and held in a local lookup keyed by `{component_identifier, kind,
  identifier}`.

  Entries that cannot be made sense of (no identifier, an action without a
  handler) are dropped with a logged warning rather than taking the report
  down with them.
  """

  require Logger

  @typedoc "An action or mode handler: an MFA or a function."
  @type handler() :: {module(), atom(), [term()]} | (-> term()) | (term() -> term())

  @type t() :: %{
          report: %{String.t() => [map()]},
          handlers: %{
            {String.t(), :action | :mode, String.t()} => %{
              handler: handler(),
              values: [String.t()] | nil
            }
          }
        }

  @doc """
  Build the full topology: the wire report plus the handler lookup.
  """
  @spec build() :: t()
  def build() do
    {assemblies, handlers} =
      normalize_groups(configured(:assemblies) ++ from_sources(:assemblies), :components, %{})

    {networks, handlers} =
      normalize_groups(configured(:networks) ++ from_sources(:networks), :peers, handlers)

    %{
      report: %{"assemblies" => assemblies, "networks" => networks},
      handlers: handlers
    }
  end

  @doc """
  The topology report as sent to NervesHub. No handlers, string keys only.
  """
  @spec report() :: %{String.t() => [map()]}
  def report(), do: build().report

  @doc """
  Look up the handler for an action on a component or peer.
  """
  @spec fetch_action(String.t(), String.t()) :: {:ok, handler()} | :error
  def fetch_action(component, action) do
    case Map.fetch(build().handlers, {component, :action, action}) do
      {:ok, %{handler: handler}} -> {:ok, handler}
      :error -> :error
    end
  end

  @doc """
  Look up the handler and allowed values for a mode on a component or peer.
  """
  @spec fetch_mode(String.t(), String.t()) ::
          {:ok, {handler(), [String.t()] | nil}} | :error
  def fetch_mode(component, mode) do
    case Map.fetch(build().handlers, {component, :mode, mode}) do
      {:ok, %{handler: handler, values: values}} -> {:ok, {handler, values}}
      :error -> :error
    end
  end

  defp config(), do: Application.get_env(:nerves_hub_link, :components, [])

  defp configured(key), do: config() |> Keyword.get(key, []) |> List.wrap()

  defp from_sources(key) do
    config()
    |> Keyword.get(:sources, [])
    |> Enum.flat_map(fn source ->
      if Code.ensure_loaded?(source) and function_exported?(source, key, 0) do
        List.wrap(apply(source, key, []))
      else
        []
      end
    end)
  rescue
    error ->
      Logger.warning("[#{inspect(__MODULE__)}] a topology source failed: #{inspect(error)}")

      []
  end

  # Assemblies and networks share a shape; only the key the member list lives
  # under differs (:components vs :peers).
  defp normalize_groups(groups, members_key, handlers) do
    Enum.reduce(groups, {[], handlers}, fn group, {acc, handlers} ->
      case identifier(group) do
        nil ->
          Logger.warning(
            "[#{inspect(__MODULE__)}] dropping #{members_key} group without an identifier: #{inspect(group)}"
          )

          {acc, handlers}

        id ->
          {members, handlers} =
            group
            |> get(members_key, [])
            |> normalize_members(handlers)

          normalized =
            %{"identifier" => id, (members_key |> to_string()) => members}
            |> put_optional("label", string_or_nil(get(group, :label)))
            |> Map.put("metrics", string_list(get(group, :metrics, [])))
            |> Map.put("metadata", string_list(get(group, :metadata, [])))

          {acc ++ [normalized], handlers}
      end
    end)
  end

  defp normalize_members(members, handlers) do
    Enum.reduce(members, {[], handlers}, fn member, {acc, handlers} ->
      case identifier(member) do
        nil ->
          Logger.warning(
            "[#{inspect(__MODULE__)}] dropping component without an identifier: #{inspect(member)}"
          )

          {acc, handlers}

        id ->
          {actions, handlers} = normalize_actions(id, get(member, :actions, []), handlers)
          {modes, handlers} = normalize_modes(id, get(member, :modes, []), handlers)

          normalized =
            %{"identifier" => id}
            |> put_optional("label", string_or_nil(get(member, :label)))
            |> Map.put("metrics", string_list(get(member, :metrics, [])))
            |> Map.put("metadata", string_list(get(member, :metadata, [])))
            |> Map.put("actions", actions)
            |> Map.put("modes", modes)

          {acc ++ [normalized], handlers}
      end
    end)
  end

  defp normalize_actions(component_id, actions, handlers) do
    Enum.reduce(actions, {[], handlers}, fn action, {acc, handlers} ->
      with id when not is_nil(id) <- identifier(action),
           handler when not is_nil(handler) <- valid_handler(get(action, :handler)) do
        wire =
          %{"identifier" => id}
          |> put_optional("label", string_or_nil(get(action, :label)))
          |> put_optional("confirm", if(get(action, :confirm) == true, do: true))

        {acc ++ [wire],
         put_handler(handlers, {component_id, :action, id}, %{handler: handler, values: nil})}
      else
        _ ->
          Logger.warning(
            "[#{inspect(__MODULE__)}] dropping action without an identifier or valid handler on \"#{component_id}\": #{inspect(action)}"
          )

          {acc, handlers}
      end
    end)
  end

  defp normalize_modes(component_id, modes, handlers) do
    Enum.reduce(modes, {[], handlers}, fn mode, {acc, handlers} ->
      with id when not is_nil(id) <- identifier(mode),
           handler when not is_nil(handler) <- valid_handler(get(mode, :handler)) do
        values = mode |> get(:values, []) |> vof() |> string_list()

        wire =
          %{"identifier" => id}
          |> put_optional("label", string_or_nil(get(mode, :label)))
          |> Map.put("metadata_key", string_or_nil(get(mode, :metadata_key)) || id)
          |> Map.put("values", values)

        {acc ++ [wire],
         put_handler(handlers, {component_id, :mode, id}, %{handler: handler, values: values})}
      else
        _ ->
          Logger.warning(
            "[#{inspect(__MODULE__)}] dropping mode without an identifier or valid handler on \"#{component_id}\": #{inspect(mode)}"
          )

          {acc, handlers}
      end
    end)
  end

  defp put_handler(handlers, key, entry) do
    if Map.has_key?(handlers, key) do
      {component, kind, id} = key

      Logger.warning(
        ~s([#{inspect(__MODULE__)}] duplicate #{kind} "#{id}" on component "#{component}"; component identifiers must be unique across the device)
      )
    end

    Map.put(handlers, key, entry)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp identifier(entry) do
    entry |> get(:identifier) |> string_or_nil()
  end

  # Entries may come from config (atom keys) or be built at runtime from
  # decoded data (string keys); accept both.
  defp get(entry, key, default \\ nil)

  defp get(entry, key, default) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> Map.get(entry, to_string(key), default)
    end
  end

  defp get(_entry, _key, default), do: default

  defp string_or_nil(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp string_or_nil(value) when is_atom(value) and not is_nil(value), do: to_string(value)
  defp string_or_nil(_value), do: nil

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&string_or_nil/1)
    |> Enum.reject(&is_nil/1)
  end

  defp string_list(_values), do: []

  defp valid_handler({m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a), do: mfa

  defp valid_handler(fun) when is_function(fun, 0) or is_function(fun, 1), do: fun

  defp valid_handler(_other), do: nil

  # A value may be given directly or as an MFA/function resolved when the
  # report is built, for lists that only exist at runtime.
  defp vof({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: apply(m, f, a)
  defp vof(fun) when is_function(fun, 0), do: fun.()
  defp vof(value), do: value
end
