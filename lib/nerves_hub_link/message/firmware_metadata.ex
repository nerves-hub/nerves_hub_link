# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Message.FirmwareMetadata do
  @moduledoc """
  Detailed firmware metadata received during the firmware update process.
  """

  defstruct [
    :architecture,
    :author,
    :description,
    :fwup_version,
    :misc,
    :platform,
    :product,
    :uuid,
    :vcs_identifier,
    :version
  ]

  @type t() :: %__MODULE__{
          architecture: String.t(),
          author: String.t() | nil,
          description: String.t() | nil,
          fwup_version: Version.build() | nil,
          misc: String.t() | nil,
          platform: String.t(),
          product: String.t(),
          uuid: binary(),
          vcs_identifier: String.t() | nil,
          version: Version.build()
        }

  @spec parse(metadata :: map()) :: {:ok, t()}
  def parse(params) do
    {:ok,
     %__MODULE__{
       architecture: params["architecture"],
       author: params["author"],
       description: params["description"],
       fwup_version: params["fwup_version"],
       misc: params["misc"],
       platform: params["platform"],
       product: params["product"],
       uuid: params["uuid"],
       vcs_identifier: params["vcs_identifier"],
       version: params["version"]
     }}
  end
end
