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
  alias NervesHubLink.Client
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UpdateManager.Updater

  require Logger

  @type status :: :idle | :updating

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            fwup_config: FwupConfig.t(),
            status: UpdateManager.status(),
            update_info: nil | UpdateInfo.t(),
            updater: nil | Updater.t(),
            updater_pid: nil | pid()
          }

    defstruct fwup_config: nil,
              status: :idle,
              update_info: nil,
              updater: nil,
              updater_pid: nil
  end

  @doc """
  Must be called when an update payload is dispatched from
  NervesHub. The map must contain a `"firmware_url"` key.
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

  @doc """
  Change `Updater` used for the next firmware update.

  `Updater`s orchestrate firmware downloads and installation.
  """
  @spec change_updater(GenServer.server(), Updater.t()) :: :ok
  def change_updater(manager \\ __MODULE__, updater) do
    GenServer.cast(manager, {:change_updater, updater})
  end

  @doc false
  @spec child_spec({FwupConfig.t(), Updater.t()}) :: Supervisor.child_spec()
  def child_spec({%FwupConfig{} = fwup_config, updater}) do
    %{
      start: {__MODULE__, :start_link, [{fwup_config, updater}, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link({FwupConfig.t(), Updater.t()}, GenServer.options()) :: GenServer.on_start()
  def start_link({%FwupConfig{} = fwup_config, updater}, opts \\ []) do
    GenServer.start_link(__MODULE__, [fwup_config, updater], opts)
  end

  @impl GenServer
  def init([%FwupConfig{} = fwup_config, updater]) do
    fwup_config = FwupConfig.validate!(fwup_config)

    # listen for updaters dying
    Process.flag(:trap_exit, true)

    {:ok, %State{fwup_config: fwup_config, updater: updater}}
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

  @impl GenServer
  def handle_cast({:change_updater, updater}, state) do
    {:noreply, %{state | updater: updater}}
  end

  @impl GenServer
  def handle_info(
        {:EXIT, updater_pid, {:shutdown, :update_complete}},
        %State{updater_pid: updater_pid} = state
      ) do
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
    Logger.info("[NervesHubLink:UpdateManager] Update completed successfully")
    NervesHubLink.send_update_status(:completed)
    Client.initiate_reboot()
    {:noreply, %State{state | status: :idle, updater_pid: nil, update_info: nil}}
  end

  def handle_info(
        {:EXIT, updater_pid, {:shutdown, {:error, reason}}},
        %State{updater_pid: updater_pid} = state
      ) do
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
    Logger.error("[NervesHubLink:UpdateManager] Update failed with reason : #{inspect(reason)}")
    NervesHubLink.send_update_status({:failed, "Update failed : #{inspect(reason)}"})
    {:noreply, %State{state | status: :idle, updater_pid: nil, update_info: nil}}
  end

  def handle_info(
        {:EXIT, updater_pid, {:shutdown, {:download_error, reason}}},
        %State{updater_pid: updater_pid} = state
      ) do
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
    Logger.error("[NervesHubLink:UpdateManager] Download failed with reason : #{inspect(reason)}")
    NervesHubLink.send_update_status({:failed, "Download failed : #{inspect(reason)}"})
    {:noreply, %State{state | status: :idle, updater_pid: nil, update_info: nil}}
  end

  def handle_info(
        {:EXIT, updater_pid, {:shutdown, {:fwup_error, reason}}},
        %State{updater_pid: updater_pid} = state
      ) do
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
    Logger.error("[NervesHubLink:UpdateManager] FWUP failed with reason : #{inspect(reason)}")
    NervesHubLink.send_update_status({:failed, "FWUP error : #{inspect(reason)}"})
    {:noreply, %State{state | status: :idle, updater_pid: nil, update_info: nil}}
  end

  def handle_info({:EXIT, _, _} = msg, state) do
    Alarms.clear_alarm(NervesHubLink.UpdateInProgress)

    Logger.error(
      "[NervesHubLink:UpdateManager] Unexpected :EXIT : pid #{inspect(msg)}, state #{inspect(state)}"
    )

    NervesHubLink.send_update_status({:failed, "Unexpected error : #{inspect(msg)}"})
    {:noreply, %{state | status: :idle, updater_pid: nil, update_info: nil}}
  end

  @spec maybe_update_firmware(UpdateInfo.t(), [binary()], State.t()) :: State.t()
  defp maybe_update_firmware(
         %UpdateInfo{} = _update_info,
         _fwup_public_keys,
         %State{status: :updating} = state
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
    NervesHubLink.send_update_status(:received)

    case Client.update_available(update_info) do
      :apply ->
        Logger.info("[NervesHubLink:UpdateManager] Starting firmware update")

        {:ok, updater_pid} =
          state.updater.start_update(update_info, state.fwup_config, fwup_public_keys)

        Alarms.set_alarm({NervesHubLink.UpdateInProgress, []})

        %State{state | status: :updating, updater_pid: updater_pid, update_info: update_info}

      :ignore ->
        NervesHubLink.send_update_status({:ignored, ""})
        Logger.info("[NervesHubLink:UpdateManager] Ignoring firmware update")
        state

      {:ignore, reason} ->
        NervesHubLink.send_update_status({:ignored, reason})
        Logger.info("[NervesHubLink:UpdateManager] Ignoring firmware update : #{reason}")
        state

      {:reschedule, ms} ->
        mins = round(ms / 60_000)
        delay_for = if(mins < 5, do: 5, else: mins)
        NervesHubLink.send_update_status({:reschedule, delay_for})

        Logger.info(
          "[NervesHubLink:UpdateManager] Requesting Hub reschedule firmware update for #{delay_for} minutes"
        )

        state

      {:reschedule, mins, reason} ->
        delay_for = if(mins < 5, do: 5, else: mins) |> round()
        NervesHubLink.send_update_status({:reschedule, delay_for, reason})

        Logger.info(
          "[NervesHubLink:UpdateManager] Requesting Hub reschedule firmware update for #{delay_for} minutes"
        )

        state
    end
  end
end
