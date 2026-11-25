# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ConfigValue do
  @moduledoc false

  # Metrics, metadata and checks are all configured the same way: a key, and
  # either the value itself or an `{module, function, args}` tuple to call for
  # it. The keys reach NervesHub as strings. Kept in one place so a change to
  # how a key is normalized isn't a change to three modules that have to agree
  # about it.

  @doc "The configured value, calling an MFA tuple for one."
  @spec resolve(term()) :: term()
  def resolve({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args),
    do: apply(mod, fun, args)

  def resolve(value), do: value

  @doc "A configured key, as a string NervesHub can store."
  @spec key(term()) :: String.t()
  def key(key) when not is_binary(key) do
    key
    |> to_string()
    |> key()
  end

  def key(key) do
    if String.printable?(key), do: key, else: inspect(key)
  end
end
