# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Message.UpdateInfo do
  @moduledoc """
  Payload received from NervesHub when an update is available.
  """

  alias NervesHubLink.Message.FirmwareMetadata

  defstruct [:firmware_url, :firmware_meta, :size, :checksum, partials_checksums: []]

  @type t() :: %__MODULE__{
          firmware_url: URI.t(),
          firmware_meta: FirmwareMetadata.t(),
          size: non_neg_integer() | nil,
          checksum: String.t() | nil,
          partials_checksums: [String.t()]
        }

  @doc """
  Parse an update message from NervesHub.

  `size`, `checksum` and `partials_checksums` describe the firmware file itself
  rather than the firmware's metadata. `checksum` is a hex encoded SHA256 of the
  whole file, and `partials_checksums` holds one hex encoded SHA256 per fixed
  size part of the file, in order. They are only sent by newer NervesHub
  servers, so they may be missing.
  """
  @spec parse(message :: map()) :: {:ok, t()} | {:error, :invalid_params}
  def parse(%{"firmware_meta" => %{} = meta, "firmware_url" => url} = params) do
    with {:ok, firmware_meta} <- FirmwareMetadata.parse(meta) do
      {:ok,
       %__MODULE__{
         firmware_url: URI.parse(url),
         firmware_meta: firmware_meta,
         size: params["size"],
         checksum: params["checksum"],
         partials_checksums: params["partials_checksums"] || []
       }}
    end
  end

  def parse(_), do: {:error, :invalid_params}
end
