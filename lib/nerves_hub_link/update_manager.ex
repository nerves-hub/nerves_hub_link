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
          | {:updating, integer()}
          | :finalizing

  @type t :: %__MODULE__{
          status: status(),
          download: nil | GenServer.server(),
          fwup: nil | GenServer.server(),
          fwup_config: FwupConfig.t(),
          update_info: nil | UpdateInfo.t()
        }

  defstruct status: :idle,
            fwup: nil,
            download: nil,
            fwup_config: nil,
            update_info: nil

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
  defp report_download(manager, message) do
    # 60 seconds is arbitrary, but currently matches the `fwup` library's
    # default timeout. Having fwup take longer than 5 seconds to perform a
    # write operation seems remote except for perhaps an exceptionally well
    # compressed delta update. The consequences of crashing here because fwup
    # doesn't have enough time are severe, though, since they prevent an
    # update.
    GenServer.call(manager, {:download, message}, 60_000)
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
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
    fwup_config = FwupConfig.validate!(fwup_config)
    {:ok, %State{fwup_config: fwup_config}}
  end

  @impl GenServer
  def handle_call(
        {:apply_update, %UpdateInfo{} = update, fwup_public_keys},
        _from,
        %State{} = state
      ) do
    {result, state} = maybe_update_firmware(update, fwup_public_keys, state)
    {:reply, result, state}
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
  def handle_call({:download, :complete}, _from, state) do
    Logger.info("[NervesHubLink] Firmware Download complete")
    {:reply, :ok, %State{state | download: nil}}
  end

  def handle_call({:download, {:error, reason}}, _from, state) do
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    {:reply, :ok, state}
  end

  # Data from the downloader is sent to fwup
  def handle_call({:download, {:data, data}}, _from, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:reply, :ok, state}
  end

  # messages from FWUP
  @impl GenServer
  def handle_info({:fwup, message}, state) do
    _ = state.fwup_config.handle_fwup_message.(message)

    case message do
      {:ok, 0, _message} ->
        Logger.info("[NervesHubLink] FWUP Finished")
        Alarms.clear_alarm(NervesHubLink.UpdateInProgress)

        {:noreply,
         %State{
           state
           | fwup: nil,
             update_info: nil,
             status: :finalizing
         }}

      {:progress, percent} ->
        {:noreply, %State{state | status: {:updating, percent}}}

      {:error, _, message} ->
        Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
        {:noreply, %State{state | status: :idle}}

      _ ->
        {:noreply, state}
    end
  end

  @spec maybe_update_firmware(UpdateInfo.t(), [binary()], State.t()) :: {atom(), State.t()}
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
    {:ignored, state}
  end

  defp maybe_update_firmware(%UpdateInfo{} = update_info, fwup_public_keys, %State{} = state) do
    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    # note: update_available is a behaviour function
    case state.fwup_config.update_available.(update_info) do
      :apply ->
        NervesHubLink.send_firmware_update_status(:updating)
        {{:updating, 0}, start_fwup_stream(update_info, fwup_public_keys, state)}

      :ignore ->
        NervesHubLink.send_firmware_update_status(:ignored)
        Logger.info("[NervesHubLink] ignoring firmware update request")
        {:ignored, %{state | status: :idle}}

      {:reschedule, minutes, :minutes} ->
        until =
          DateTime.utc_now()
          |> DateTime.add(minutes, :minute)

        NervesHubLink.send_firmware_update_status(:reschedule, %{until: until})
        Logger.info("[NervesHubLink] rescheduling firmware update in #{minutes} minutes")
        {:rescheduled, %{state | status: :idle}}

      {:reschedule, ms} ->
        until =
          DateTime.utc_now()
          |> DateTime.add(ms, :millisecond)

        NervesHubLink.send_firmware_update_status(:reschedule, %{until: until})
        Logger.info("[NervesHubLink] rescheduling firmware update in #{ms / 1_000} seconds")
        {:rescheduled, %{state | status: :idle}}
    end
  end

  @spec start_fwup_stream(UpdateInfo.t(), [binary()], State.t()) :: State.t()
  defp start_fwup_stream(%UpdateInfo{} = update_info, fwup_public_keys, state) do
    pid = self()
    fun = &report_download(pid, &1)
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

  @spec fwup_args(FwupConfig.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%FwupConfig{} = config, fwup_public_keys) do
    args = ["--apply", "--no-unmount", "-d", config.fwup_devpath, "--task", config.fwup_task]

    Enum.reduce(fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end
end
