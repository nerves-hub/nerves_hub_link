defmodule NervesHubLink.Message.UpdateInfo do
  @moduledoc """
  Payload received from NervesHub when an update is available.
  """

  alias NervesHubLink.Message.FirmwareMetadata

  defstruct [:firmware_url, :firmware_meta]

  @type t() :: %__MODULE__{
          firmware_url: URI.t(),
          firmware_meta: FirmwareMetadata.t()
        }

  @doc "Parse an update message from NervesHub."
  @spec parse(message :: map()) :: {:ok, t()} | {:error, :invalid_params}
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
