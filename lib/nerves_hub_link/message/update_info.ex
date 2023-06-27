defmodule NervesHubLink.Message.UpdateInfo do
  @moduledoc false

  alias NervesHubLink.Message.FirmwareMetadata

  defstruct [:firmware_url, :firmware_meta]

  @typedoc """
  Payload that gets dispatched down to devices upon an update

  `firmware_url` and `firmware_meta` are only available
  when `update_available` is true.
  """
  @type t() :: %__MODULE__{
          firmware_url: URI.t(),
          firmware_meta: FirmwareMetadata.t()
        }

  @doc "Parse an update message from NervesHub"
  @spec parse(map()) :: {:ok, t()} | {:error, :invalid_params}
  def parse(%{"firmware_meta" => %{} = meta, "firmware_url" => url}) do
    with {:ok, firmware_meta} <- FirmwareMetadata.parse(meta) do
      {:ok,
       %__MODULE__{
         firmware_url: URI.parse(url),
         firmware_meta: firmware_meta
       }}
    end
  end

  def parse(_), do: {:error, :invalid_params}
end
