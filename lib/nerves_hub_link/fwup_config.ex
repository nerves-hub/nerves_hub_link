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
            fwup_task: ""

  @type t :: %__MODULE__{
          fwup_devpath: Path.t(),
          fwup_task: String.t(),
          fwup_env: [{String.t(), String.t()}]
        }

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
