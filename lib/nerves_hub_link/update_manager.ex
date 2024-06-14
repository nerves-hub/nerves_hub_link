defmodule NervesHubLink.UpdateManager do
  @moduledoc """
  GenServer responsible for brokering messages between:
    * an external controlling process
    * FWUP
    * HTTP

  Should be started in a supervision tree
  """
  use GenServer

  alias NervesHubLink.{Downloader, FwupConfig}
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.Socket

  require Logger

  defmodule State do
    @moduledoc """
    Structure for the state of the `UpdateManager` server.
    Contains types that describe status and different states the
    `UpdateManager` can be in
    """

    @type status ::
            :idle
            | {:fwup_error, String.t()}
            | :update_rescheduled
            | {:updating, integer()}

    @type previous_update :: :complete | :failed

    @type t :: %__MODULE__{
            status: status(),
            update_reschedule_timer: nil | :timer.tref(),
            download: nil | GenServer.server(),
            fwup: nil | GenServer.server(),
            fwup_config: FwupConfig.t(),
            update_info: nil | UpdateInfo.t(),
            retrying: boolean(),
            previous_update: nil | previous_update()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              fwup: nil,
              download: nil,
              fwup_config: nil,
              update_info: nil,
              retrying: false,
              previous_update: nil
  end

  @doc """
  Must be called when an update payload is dispatched from
  NervesHub. the map must contain a `"firmware_url"` key.
  """
  @spec apply_update(GenServer.server(), UpdateInfo.t(), list(String.t())) :: State.status()
  def apply_update(manager \\ __MODULE__, %UpdateInfo{} = update_info, fwup_public_keys) do
    GenServer.call(manager, {:apply_update, update_info, fwup_public_keys})
  end

  @doc """
  Returns the current status of the update manager
  """
  @spec status(GenServer.server()) :: State.status()
  def status(manager \\ __MODULE__) do
    GenServer.call(manager, :status)
  end

  @doc """
  Returns the previous status of the update manager
  """
  @spec previous_update(GenServer.server()) :: State.previous_update()
  def previous_update(manager \\ __MODULE__) do
    GenServer.call(manager, :previous_update)
  end

  @doc """
  Returns the UUID of the currently downloading firmware, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(manager \\ __MODULE__) do
    GenServer.call(manager, :currently_downloading_uuid)
  end

  @doc false
  @spec child_spec(FwupConfig.t()) :: Supervisor.child_spec()
  def child_spec(%FwupConfig{} = args) do
    %{
      start: {__MODULE__, :start_link, [args, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link(FwupConfig.t(), GenServer.options()) :: GenServer.on_start()
  def start_link(%FwupConfig{} = args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl GenServer
  def init(%FwupConfig{} = fwup_config) do
    :alarm_handler.clear_alarm(NervesHubLink.UpdateInProgress)
    fwup_config = FwupConfig.validate!(fwup_config)
    {:ok, %State{fwup_config: fwup_config}}
  end

  @impl GenServer
  def handle_call(
        {:apply_update, %UpdateInfo{} = update, fwup_public_keys},
        from,
        %State{} = state
      ) do
    state = maybe_update_firmware(update, fwup_public_keys, elem(from, 0), state)
    {:reply, state.status, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{update_info: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{} = state) do
    {:reply, state.update_info.firmware_meta.uuid, state}
  end

  def handle_call(:status, _from, %State{} = state) do
    {:reply, state.status, state}
  end

  def handle_call(:previous_update, _from, %State{} = state) do
    {:reply, state.previous_update, state}
  end

  @impl GenServer
  def handle_info({:update_reschedule, response, fwup_public_keys, reporting_pid}, state) do
    {:noreply,
     maybe_update_firmware(response, fwup_public_keys, reporting_pid, %State{
       state
       | update_reschedule_timer: nil
     })}
  end

  # messages from FWUP
  def handle_info({:fwup, message}, state) do
    _ = state.fwup_config.handle_fwup_message.(message)

    case message do
      {:ok, 0, _message} ->
        Logger.info("[NervesHubLink] FWUP Finished")
        :alarm_handler.clear_alarm(NervesHubLink.UpdateInProgress)
        {:noreply, %State{state | fwup: nil, update_info: nil, status: :idle}}

      {:progress, percent} ->
        {:noreply, %State{state | status: {:updating, percent}}}

      {:error, _, message} ->
        :alarm_handler.clear_alarm(NervesHubLink.UpdateInProgress)
        {:noreply, %State{state | status: {:fwup_error, message}}}

      _ ->
        {:noreply, state}
    end
  end

  # messages from Downloader
  def handle_info({:download, :complete, _fwup_public_keys, reporting_pid}, state) do
    Logger.info("[NervesHubLink] Firmware Download complete")
    Socket.send_update_status(reporting_pid, :complete)
    {:noreply, %State{state | status: :idle}}
  end

  def handle_info(
        {:download, {:error, %Mint.HTTPError{reason: {:http_error, 401}}}, _fwup_public_keys,
         reporting_pid},
        state
      ) do
    Logger.error("[NervesHubLink] Firmware download error: 401")
    Socket.send_update_status(reporting_pid, {:error, :download_unauthorized})
    {:noreply, %State{state | status: :idle}}
  end

  def handle_info({:download, {:error, reason}, _fwup_public_keys, reporting_pid}, state) do
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    Socket.send_update_status(reporting_pid, {:error, :non_fatal})
    {:noreply, %State{state | status: :idle}}
  end

  # Data from the downloader is sent to fwup
  def handle_info({:download, {:data, data}, _fwup_public_keys, _reporting_pid}, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, {:http_error, 401}}, state) do
    {:noreply, %State{state | download: nil}}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  @spec maybe_update_firmware(UpdateInfo.t(), [binary()], pid(), State.t()) ::
          State.t()
  defp maybe_update_firmware(
         %UpdateInfo{} = _update_info,
         _fwup_public_keys,
         _reporting_pid,
         %State{status: {:updating, _percent}} = state
       ) do
    # Received an update message from NervesHub, but we're already in progress.
    # It could be because the deployment/device was edited making a duplicate
    # update message or a new deployment was created. Either way, lets not
    # interrupt FWUP and let the task finish. After update and reboot, the
    # device will check-in and get an update message if it was actually new and
    # required
    state
  end

  defp maybe_update_firmware(
         %UpdateInfo{} = update_info,
         fwup_public_keys,
         reporting_pid,
         %State{} = state
       ) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    # note: update_available is a behaviour function
    case state.fwup_config.update_available.(update_info) do
      :apply ->
        Socket.send_update_status(reporting_pid, :starting)
        start_fwup_stream(update_info, fwup_public_keys, reporting_pid, state)

      :ignore ->
        Socket.send_update_status(reporting_pid, :ignored)
        state

      {:reschedule, ms} ->
        timer =
          Process.send_after(
            self(),
            {:update_reschedule, update_info, fwup_public_keys, reporting_pid},
            ms
          )

        Logger.info("[NervesHubLink] rescheduling firmware update in #{ms} milliseconds")
        Socket.send_update_status(reporting_pid, {:rescheduled, ms, rescheduled_to(ms)})
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  defp maybe_update_firmware(_, _, _, state), do: state

  defp rescheduled_to(ms) do
    Time.utc_now()
    |> Time.truncate(:millisecond)
    |> Time.add(ms, :millisecond)
  end

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    %{state | update_reschedule_timer: nil}
  end

  @spec start_fwup_stream(UpdateInfo.t(), [binary()], pid(), State.t()) :: State.t()
  defp start_fwup_stream(%UpdateInfo{} = update_info, [] = fwup_public_keys, reporting_pid, state) do
    pid = self()

    Process.flag(:trap_exit, true)

    fun = &send(pid, {:download, &1, fwup_public_keys, reporting_pid})
    {:ok, download} = Downloader.start_download(update_info.firmware_url, fun)

    {:ok, fwup} =
      Fwup.stream(pid, fwup_args(state.fwup_config, fwup_public_keys),
        fwup_env: state.fwup_config.fwup_env
      )

    Logger.info("[NervesHubLink] Downloading firmware: #{update_info.firmware_url}")
    :alarm_handler.set_alarm({NervesHubLink.UpdateInProgress, []})

    %State{
      state
      | status: {:updating, 0},
        download: download,
        fwup: fwup,
        update_info: update_info
    }
  end

  @spec fwup_args(FwupConfig.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%FwupConfig{} = config, [] = fwup_public_keys) do
    args = ["--apply", "--no-unmount", "-d", config.fwup_devpath, "--task", config.fwup_task]

    Enum.reduce(fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end
end
