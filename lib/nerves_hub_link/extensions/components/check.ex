# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Check do
  @moduledoc false

  # The rules NervesHub applies to what the components extension sends, in one
  # place so the snapshot, readings and state checks can't disagree about them.
  # Each mirrors what the platform refuses: a value that passes here is one
  # NervesHub accepts.

  @namespace_pattern ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @name_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @max_string_length 255
  @max_state_value_length 64

  @doc "The longest state value NervesHub stores, in characters."
  @spec max_state_value_length() :: 64
  def max_state_value_length(), do: @max_state_value_length

  @doc """
  A namespace, as a string: lower case letters, digits and `_`, starting with a
  letter, at most 32 characters. An atom is accepted for convenience.
  """
  @spec namespace(term()) :: {:ok, String.t()} | {:error, String.t()}
  def namespace(namespace) do
    with {:ok, namespace} <- text(namespace, "namespace") do
      if Regex.match?(@namespace_pattern, namespace),
        do: {:ok, namespace},
        else:
          {:error,
           "namespace #{inspect(namespace)} must match #{inspect(@namespace_pattern.source)}"}
    end
  end

  @doc """
  A key in a component's `versions`, as a string: written as a namespace is.
  An atom is accepted, since `firmware:` is how Elixir code writes one.
  """
  @spec version_key(term()) :: {:ok, String.t()} | {:error, String.t()}
  def version_key(key) do
    with {:ok, key} <- text(key, "version key") do
      if Regex.match?(@namespace_pattern, key),
        do: {:ok, key},
        else:
          {:error, "version key #{inspect(key)} must match #{inspect(@namespace_pattern.source)}"}
    end
  end

  @doc """
  A reading or state name, as a string: lower case letters, digits and `_`,
  starting with a letter, at most 64 characters.
  """
  @spec name(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def name(name, what) do
    with {:ok, name} <- text(name, what) do
      if Regex.match?(@name_pattern, name),
        do: {:ok, name},
        else: {:error, "#{what} #{inspect(name)} must match #{inspect(@name_pattern.source)}"}
    end
  end

  @doc """
  A required string: present, not empty, and no longer than `max` characters.
  """
  @spec required(term(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def required(value, what, max \\ @max_string_length) do
    with {:ok, value} <- string(value, what) do
      cond do
        value == "" -> {:error, "#{what} is empty"}
        too_long?(value, max) -> {:error, "#{what} is longer than #{max} characters"}
        true -> {:ok, value}
      end
    end
  end

  @doc """
  An optional string. `nil` and `""` are both left out, as NervesHub reads an
  empty one as absent.
  """
  @spec optional(term(), String.t(), pos_integer()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def optional(value, what, max \\ @max_string_length)
  def optional(nil, _what, _max), do: {:ok, nil}
  def optional("", _what, _max), do: {:ok, nil}
  def optional(value, what, max), do: required(value, what, max)

  @doc "A timestamp for the wire: ISO 8601 with an offset."
  @spec timestamp(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def timestamp(%DateTime{} = at, _what), do: {:ok, DateTime.to_iso8601(at)}

  def timestamp(at, what) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, _parsed, _offset} -> {:ok, at}
      {:error, _reason} -> {:error, "#{what} #{inspect(at)} is not ISO 8601 with an offset"}
    end
  end

  def timestamp(at, what),
    do: {:error, "#{what} must be a DateTime, got #{inspect(at, limit: 5)}"}

  @doc "Now, as the platform reads a device's clock."
  @spec now() :: DateTime.t()
  def now(), do: DateTime.utc_now() |> DateTime.truncate(:millisecond)

  # A name or value written as an atom (`:lock`, `:unlocked`) is the natural
  # thing to write in Elixir, and the wire has no atoms to lose.
  defp text(value, what) when is_atom(value) and value not in [nil, true, false],
    do: string(Atom.to_string(value), what)

  defp text(value, what), do: string(value, what)

  # NervesHub refuses a string that isn't valid UTF-8, since PostgreSQL can't
  # store it.
  defp string(value, what) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, "#{what} is not valid UTF-8"}
  end

  defp string(nil, what), do: {:error, "#{what} is missing"}

  defp string(value, what),
    do: {:error, "#{what} must be a string, got #{inspect(value, limit: 5)}"}

  # In code points, which is how PostgreSQL counts a varchar and so how
  # NervesHub counts the limit. A grapheme count would let through a string
  # made of combining characters that the platform then refuses.
  defp too_long?(value, max), do: length(String.to_charlist(value)) > max
end
