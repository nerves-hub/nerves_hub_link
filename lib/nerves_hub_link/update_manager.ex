# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Connor Rigby
# SPDX-FileCopyrightText: 2024 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager do
  @moduledoc """
  GenServer responsible for brokering messages between:
    * an external controlling process
    * FWUP
    * HTTP

  Should be started in a supervision tree
  """
  use GenServer

  alias NervesHubLink.Alarms
  alias NervesHubLink.Downloader
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.UpdateManager

  require Logger

  @type status ::
          :idle
          | {:fwup_error, String.t()}
          | :update_rescheduled
          | {:downloading, integer()}
          | {:updating, integer()}
          | :applying

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            status: UpdateManager.status(),
            update_reschedule_timer: nil | :timer.tref(),
            download: nil | GenServer.server(),
            downloader_config: map(),
            cached_download_pid: nil | pid(),
            cached_download_path: nil | String.t(),
            fwup: nil | GenServer.server(),
            fwup_config: FwupConfig.t(),
            update_info: nil | UpdateInfo.t()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              fwup: nil,
              download: nil,
              downloader_config: nil,
              cached_download_pid: nil,
              cached_download_path: nil,
              fwup_config: nil,
              update_info: nil
  end

  @doc """
  Must be called when an update payload is dispatched from
  NervesHub. the map must contain a `"firmware_url"` key.
  """
  @spec apply_update(GenServer.server(), UpdateInfo.t(), list(String.t())) ::
          UpdateManager.status()
  def apply_update(manager \\ __MODULE__, %UpdateInfo{} = update_info, fwup_public_keys) do
    GenServer.call(manager, {:apply_update, update_info, fwup_public_keys})
  end

  @doc """
  Returns the current status of the update manager
  """
  @spec status(GenServer.server()) :: UpdateManager.status()
  def status(manager \\ __MODULE__) do
    GenServer.call(manager, :status)
  end

  @doc """
  Returns the UUID of the currently downloading firmware, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(manager \\ __MODULE__) do
    GenServer.call(manager, :currently_downloading_uuid)
  end

  # Private API for reporting download progress. This wraps a GenServer.call so
  # that it can apply back pressure to the downloader if applying the update is
  # slow.
  defp report_stream(manager, message) do
    # 60 seconds is arbitrary, but currently matches the `fwup` library's
    # default timeout. Having fwup take longer than 5 seconds to perform a
    # write operation seems remote except for perhaps an exceptionally well
    # compressed delta update. The consequences of crashing here because fwup
    # doesn't have enough time are severe, though, since they prevent an
    # update.
    GenServer.call(manager, {:stream, message}, 60_000)
  end

  defp report_download(manager, message, fwup_public_keys) do
    # 60 seconds is arbitrary, but currently matches the `fwup` library's
    # default timeout. Having fwup take longer than 5 seconds to perform a
    # write operation seems remote except for perhaps an exceptionally well
    # compressed delta update. The consequences of crashing here because fwup
    # doesn't have enough time are severe, though, since they prevent an
    # update.
    GenServer.call(manager, {:download, message, fwup_public_keys}, 60_000)
  end

  @doc false
  @spec child_spec({FwupConfig.t(), map()}) :: Supervisor.child_spec()
  def child_spec({%FwupConfig{} = _fwup_config, %{}} = args) do
    %{
      start: {__MODULE__, :start_link, [args, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link({FwupConfig.t(), map()}, GenServer.options()) :: GenServer.on_start()
  def start_link({%FwupConfig{} = _fwup_config, %{}} = args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl GenServer
  def init({%FwupConfig{} = fwup_config, downloader_config}) do
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
    fwup_config = FwupConfig.validate!(fwup_config)

    {:ok, %State{fwup_config: fwup_config, downloader_config: downloader_config}}
  end

  @impl GenServer
  def handle_call(
        {:apply_update, %UpdateInfo{} = update, fwup_public_keys},
        _from,
        %State{} = state
      ) do
    state = maybe_update_firmware(update, fwup_public_keys, state)
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

  # messages from Downloader
  def handle_call({:stream, :complete}, _from, state) do
    Logger.info("[NervesHubLink] Firmware Download complete")
    {:reply, :ok, %State{state | download: nil}}
  end

  def handle_call({:stream, {:error, reason}}, _from, state) do
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    {:reply, :ok, state}
  end

  # Data from the downloader is sent to fwup
  def handle_call({:stream, {:data, data, _percent}}, _from, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:reply, :ok, state}
  end

  # messages from Downloader
  def handle_call({:download, :complete, fwup_public_keys}, _from, state) do
    :ok = File.close(state.cached_download_pid)

    firmware_file_path = String.trim_trailing(state.cached_download_path, ".partial")
    :ok = File.rename(state.cached_download_path, firmware_file_path)

    stat = File.stat(firmware_file_path)

    Logger.info("[NervesHubLink] Firmware download complete (#{stat.size} bytes)")

    send(self(), {:send_cached_firmware_to_fwup, firmware_file_path, fwup_public_keys})

    {:reply, :ok,
     %State{
       state
       | download: nil,
         cached_download_pid: nil,
         cached_download_path: firmware_file_path
     }}
  end

  def handle_call({:download, {:error, reason}}, _from, state) do
    :ok = File.close(state.cached_download_pid)
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    {:reply, :ok, state}
  end

  # Data from the downloader is sent to fwup
  def handle_call({:download, {:data, data, percent}}, _from, state) do
    IO.binwrite(state.cached_download_pid, data)

    NervesHubLink.send_update_progress(round(percent))

    {:reply, :ok, %State{state | status: {:downloading, percent}}}
  end

  @impl GenServer
  def handle_info({:update_reschedule, response, fwup_public_keys}, state) do
    {:noreply,
     maybe_update_firmware(response, fwup_public_keys, %State{
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
        Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
        {:noreply, %State{state | fwup: nil, update_info: nil, status: :idle}}

      {:progress, percent} ->
        {:noreply, %State{state | status: {:updating, percent}}}

      {:error, _, message} ->
        Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
        {:noreply, %State{state | status: {:fwup_error, message}}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:send_cached_firmware_to_fwup, firmware_path, fwup_public_keys}, state) do
    public_keys =
      Enum.reduce(fwup_public_keys, [], fn public_key, args ->
        args ++ ["--public-key", public_key]
      end)

    Logger.info("[NervesHubLink] Requesting FWUP apply the firmware update : #{firmware_path}")

    {:ok, fwup} =
      Fwup.apply(state.fwup_config.fwup_devpath, state.fwup_config.fwup_task, firmware_path,
        fwup_env: public_keys
      )

    {:noreply, %State{state | status: :applying, fwup: fwup}}
  end

  @spec maybe_update_firmware(UpdateInfo.t(), [binary()], State.t()) :: State.t()
  defp maybe_update_firmware(
         %UpdateInfo{} = _update_info,
         _fwup_public_keys,
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

  defp maybe_update_firmware(%UpdateInfo{} = update_info, fwup_public_keys, %State{} = state) do
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
        if state.downloader_config[:cache_firmware_to_disk] do
          start_cached_fwup_stream(update_info, fwup_public_keys, state)
        else
          start_fwup_stream(update_info, fwup_public_keys, state)
        end

      :ignore ->
        state

      {:reschedule, ms} ->
        timer =
          Process.send_after(self(), {:update_reschedule, update_info, fwup_public_keys}, ms)

        Logger.info("[NervesHubLink] rescheduling firmware update in #{ms} milliseconds")
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  defp maybe_update_firmware(_, _, state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    %{state | update_reschedule_timer: nil}
  end

  @spec start_fwup_stream(UpdateInfo.t(), [binary()], State.t()) :: State.t()
  defp start_fwup_stream(%UpdateInfo{} = update_info, fwup_public_keys, state) do
    pid = self()
    fun = &report_stream(pid, &1)
    {:ok, download} = Downloader.start_download(update_info.firmware_url, fun)

    {:ok, fwup} =
      Fwup.stream(pid, fwup_args(state.fwup_config, fwup_public_keys),
        fwup_env: state.fwup_config.fwup_env
      )

    Logger.info("[NervesHubLink] Downloading firmware: #{update_info.firmware_url}")
    Alarms.set_alarm({NervesHubLink.UpdateInProgress, []})

    %State{
      state
      | status: {:updating, 0},
        download: download,
        fwup: fwup,
        update_info: update_info
    }
  end

  defp start_cached_fwup_stream(%UpdateInfo{} = update_info, fwup_public_keys, state) do
    path_parts = String.split(update_info.firmware_url, "/")
    file_name_with_query = List.last(path_parts)
    file_name = String.replace(file_name_with_query, ~r/\?.*/, "")

    firmware_dir = state.downloader_config.cache_firmware_dir

    full_path = Path.join(firmware_dir, "#{file_name}.partial")

    start_from =
      case File.stat(full_path) do
        {:ok, stat} ->
          Logger.info("[NervesHubLink] Partial firmware download exists (#{stat.size} bytes)")
          stat.size

        {:error, _} ->
          _ = File.rmdir(firmware_dir)
          :ok = File.mkdir_p(firmware_dir)
          0
      end

    file_pid = File.open!("#{file_name}.partial", [:read, :write, :append, :binary])

    pid = self()
    fun = &report_download(pid, &1, fwup_public_keys)

    {:ok, download} =
      Downloader.start_download(update_info.firmware_url, fun, resume_from_bytes: start_from)

    Logger.info("[NervesHubLink] Downloading firmware: #{update_info.firmware_url}")
    Alarms.set_alarm({NervesHubLink.UpdateInProgress, []})

    %State{
      state
      | status: {:downloading, 0},
        download: download,
        update_info: update_info,
        cached_download_pid: file_pid,
        cached_download_path: full_path
    }
  end

  @spec fwup_args(FwupConfig.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%FwupConfig{} = config, fwup_public_keys) do
    args = ["--apply", "--no-unmount", "-d", config.fwup_devpath, "--task", config.fwup_task]

    Enum.reduce(fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end
end
