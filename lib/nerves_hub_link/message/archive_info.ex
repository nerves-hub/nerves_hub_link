defmodule NervesHubLink.Message.ArchiveInfo do
  @moduledoc false

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

  @typedoc """
  Payload that gets dispatched down to devices upon an archive being available
  """
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

  @doc "Parse an update message from NervesHub"
  @spec parse(map()) :: {:ok, t()}
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
