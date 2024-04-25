defmodule NervesHubLink.ArchiveManager do
  @moduledoc """
  GenServer for handling downloading archives from NervesHub

  Your NervesHubLink client will tell the manager when to download
  an archive and the Manager will tell your client when it's done
  downloading so you can act on it.

  You are expected to remove the file when you're done with it and track
  that it has been applied to prevent downloading again.
  """

  use GenServer

  alias NervesHubLink.Downloader
  alias NervesHubLink.Message.ArchiveInfo

  require Logger

  @type status :: :idle | :downloading | :done | :update_rescheduled

  @type t :: %__MODULE__{
          archive_info: nil | ArchiveInfo.t(),
          archive_public_keys: [binary()],
          client: NervesHubLink.Client,
          data_path: Path.t(),
          download: nil | GenServer.server(),
          file_path: Path.t(),
          status: status(),
          temp_file_path: Path.t(),
          update_reschedule_timer: nil | :timer.tref()
        }

  defstruct archive_info: nil,
            archive_public_keys: [],
            client: nil,
            data_path: nil,
            download: nil,
            file_path: nil,
            status: :idle,
            temp_file_path: nil,
            update_reschedule_timer: nil

  @doc """
  Must be called when an archive payload is dispatched from
  NervesHub. the map must contain a `"url"` key.
  """
  @spec apply_archive(GenServer.server(), ArchiveInfo.t()) :: status()
  def apply_archive(manager \\ __MODULE__, %ArchiveInfo{} = archive_info) do
    GenServer.call(manager, {:apply_archive, archive_info})
  end

  @doc """
  Returns the current status of the archive manager
  """
  @spec status(GenServer.server()) :: status()
  def status(manager \\ __MODULE__) do
    GenServer.call(manager, :status)
  end

  @doc """
  Returns the UUID of the currently downloading archive, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(manager \\ __MODULE__) do
    GenServer.call(manager, :currently_downloading_uuid)
  end

  @doc false
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(args) do
    %{
      start: {__MODULE__, :start_link, [args, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl GenServer
  def init(args) do
    state = %__MODULE__{
      archive_public_keys: args.archive_public_keys,
      client: args.client,
      data_path: args.data_path
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:apply_archive, %ArchiveInfo{} = info}, _from, %__MODULE__{} = state) do
    state = maybe_update_archive(info, state)
    {:reply, state.status, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %__MODULE__{archive_info: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %__MODULE__{} = state) do
    {:reply, state.archive_info.uuid, state}
  end

  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_info({:update_reschedule, response}, state) do
    {:noreply, maybe_update_archive(response, %__MODULE__{state | update_reschedule_timer: nil})}
  end

  # messages from Downloader
  def handle_info({:download, :complete}, state) do
    Logger.info("[NervesHubLink] Archive Download complete")

    # Clear a potential old file since we finished downloading
    _ = File.rm_rf(state.file_path)
    _ = File.rename(state.temp_file_path, state.file_path)

    # validate the file

    if valid_archive?(state.file_path, state.archive_public_keys) do
      _ = state.client.archive_ready(state.archive_info, state.file_path)
    else
      Logger.error(
        "[NervesHubLink] Archive could not be validated, your public keys are configured wrong"
      )
    end

    {:noreply,
     %__MODULE__{
       state
       | archive_info: nil,
         file_path: nil,
         temp_file_path: nil,
         download: nil,
         status: :idle
     }}
  end

  def handle_info({:download, {:error, reason}}, state) do
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Data from the downloader
  def handle_info({:download, {:data, data}}, state) do
    :ok =
      File.open!(state.temp_file_path, [:append], fn fd ->
        IO.binwrite(fd, data)
      end)

    {:noreply, state}
  end

  defp maybe_update_archive(info, state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    uri = URI.parse(info.url)
    file_name = Path.basename(uri.path)
    file_path = Path.join(state.data_path, "archives/#{file_name}")
    temp_file_path = Path.join(state.data_path, "archives/#{file_name}.download")
    directory = Path.dirname(file_path)

    pid = self()

    case state.client.archive_available(info) do
      :download ->
        {:ok, download} = Downloader.start_download(info.url, &send(pid, {:download, &1}))

        _ = File.mkdir_p(directory)
        _ = File.rm_rf(temp_file_path)
        _ = File.touch(temp_file_path)

        %__MODULE__{
          state
          | archive_info: info,
            file_path: file_path,
            temp_file_path: temp_file_path,
            download: download,
            status: :downloading
        }

      :ignore ->
        state

      {:reschedule, ms} ->
        timer = Process.send_after(self(), {:update_reschedule, info}, ms)
        Logger.info("[NervesHubLink] rescheduling archive in #{ms} milliseconds")
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    %{state | update_reschedule_timer: nil}
  end

  def valid_archive?(file_path, public_keys) do
    args = ["-V", "-i", file_path]

    args =
      Enum.reduce(public_keys, args, fn public_key, args ->
        args ++ ["--public-key", public_key]
      end)

    {_output, exit_code} = System.cmd("fwup", args)

    exit_code == 0
  end
end
