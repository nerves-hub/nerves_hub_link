# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.FwupConfig do
  @moduledoc """
  Config structure responsible for:

  - applying a fwupdate,
  - and storing fwup task configuration
  """

  defstruct fwup_devpath: "",
            fwup_env: [],
            fwup_extra_options: [],
            fwup_task: ""

  @type t :: %__MODULE__{
          fwup_devpath: Path.t(),
          fwup_task: String.t(),
          fwup_extra_options: [String.t()],
          fwup_env: [{String.t(), String.t()}]
        }

  @doc """
  Returns true when at least one usable public key is available to verify a
  firmware or archive signature.

  `fwup` only verifies a signature when it is given at least one `--public-key`,
  so an empty list means an image would be applied unverified. Non-binary
  entries are ignored, matching the filtering done in
  `NervesHubLink.Configurator`, so that a malformed key list cannot stand in for
  a real one.
  """
  @spec signing_keys_available?([binary()]) :: boolean()
  def signing_keys_available?(public_keys) when is_list(public_keys),
    do: Enum.any?(public_keys, &is_binary/1)

  def signing_keys_available?(_public_keys), do: false

  @doc "Raises an ArgumentError on invalid arguments"
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = args) do
    args
    |> validate_fwup_devpath!()
    |> validate_fwup_task!()
    |> validate_fwup_env!()
  end

  defp validate_fwup_devpath!(%__MODULE__{fwup_devpath: devpath} = args) when is_binary(devpath),
    do: args

  defp validate_fwup_devpath!(%__MODULE__{}),
    do: raise(ArgumentError, message: "invalid arg: fwup_devpath")

  defp validate_fwup_task!(%__MODULE__{fwup_task: task} = args) when is_binary(task),
    do: args

  defp validate_fwup_task!(%__MODULE__{}),
    do: raise(ArgumentError, message: "invalid arg: fwup_task")

  defp validate_fwup_env!(%__MODULE__{fwup_env: list} = args) when is_list(list),
    do: args

  defp validate_fwup_env!(%__MODULE__{}),
    do: raise(ArgumentError, message: "invalid arg: fwup_env")
end
