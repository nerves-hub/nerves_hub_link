defmodule NervesHubLink.UploadFile do
  @moduledoc false

  #
  # Upload files in a separate process from the socket
  #

  use GenServer

  alias NervesHubLink.Socket

  defmodule State do
    @type t() :: %__MODULE__{
            file_path: Path.t(),
            socket_pid: pid()
          }

    defstruct [:file_path, :socket_pid]
  end

  @spec start_link(Path.t(), pid()) :: GenServer.on_start()
  def start_link(file_path, socket_pid) do
    GenServer.start_link(__MODULE__, file_path: file_path, socket_pid: socket_pid)
  end

  @impl true
  def init(opts) do
    state = %State{
      file_path: opts[:file_path],
      socket_pid: opts[:socket_pid]
    }

    {:ok, state, {:continue, :download}}
  end

  @impl true
  def handle_continue(:download, state) do
    filename = Path.basename(state.file_path)

    :ok = Socket.start_uploading(state.socket_pid, filename)

    File.stream!(state.file_path, 1024)
    |> Stream.with_index()
    |> Stream.each(fn {chunk, index} ->
      :ok = Socket.upload_data(state.socket_pid, filename, index, chunk)
    end)
    |> Stream.run()

    :ok = Socket.finish_uploading(state.socket_pid, filename)

    {:noreply, state}
  end
end
