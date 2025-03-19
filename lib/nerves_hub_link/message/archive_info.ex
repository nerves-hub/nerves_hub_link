# SPDX-FileCopyrightText: 2024 Eric Oestrich
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Message.ArchiveInfo do
  @moduledoc """
  Payload received from NervesHub when an archive is available.
  """

  defstruct [
    :architecture,
    :description,
    :platform,
    :size,
    :uploaded_at,
    :url,
    :uuid,
    :version
  ]

  @type t() :: %__MODULE__{
          architecture: String.t(),
          description: String.t(),
          platform: String.t(),
          size: integer(),
          uploaded_at: DateTime.t(),
          url: URI.t(),
          uuid: String.t(),
          version: Version.t()
        }

  @doc "Parse an update message from NervesHub."
  @spec parse(message :: map()) :: {:ok, t()}
  def parse(params) do
    {:ok,
     %__MODULE__{
       architecture: params["architecture"],
       description: params["description"],
       platform: params["platform"],
       size: params["size"],
       uploaded_at: params["uploaded_at"],
       uuid: params["uuid"],
       url: params["url"],
       version: params["version"]
     }}
  end
end
