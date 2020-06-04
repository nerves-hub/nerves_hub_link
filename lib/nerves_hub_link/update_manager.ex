defmodule NervesHubLink.UpdateManager do
  use GenServer
  require Logger

  alias NervesHubLink.{DeviceChannel, Client, HTTPFwupStream}

  defmodule State do
    @type status ::
            :idle
            | :fwup_error
            | :update_failed
            | :update_rescheduled
            | {:updating, integer()}
            | :unknown

    @type t :: %__MODULE__{
            status: status(),
            update_reschedule_timer: nil | pid()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def apply_update(update) do
    GenServer.call(__MODULE__, {:apply_update, update})
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def init(_opts) do
    {:ok, %State{}}
  end

  def handle_call({:apply_update, update}, _from, state) do
    state = maybe_update_firmware(update, state)
    {:reply, state.status, state}
  end

  def handle_call(:status, _from, %{status: status} = state) do
    {:reply, status, state}
  end

  def handle_info({:fwup, {:ok, 0, _message} = full_message}, state) do
    Logger.info("[NervesHubLink] FWUP Finished")
    _ = Client.handle_fwup_message(full_message)
    Nerves.Runtime.reboot()
    {:noreply, state}
  end

  def handle_info({:fwup, message}, state) do
    state =
      case message do
        {:progress, percent} ->
          DeviceChannel.send_update_progress(percent)
          %{state | status: {:updating, percent}}

        {:error, _, _message} ->
          DeviceChannel.send_update_status("fwup error")
          %{state | status: :fwup_error}

        _ ->
          state
      end

    _ = Client.handle_fwup_message(message)
    {:noreply, state}
  end

  def handle_info({:http_error, error}, state) do
    _ = Client.handle_error(error)
    DeviceChannel.send_update_status("update failed")
    {:noreply, %{state | status: :update_failed}}
  end

  def handle_info({:update_reschedule, response}, state) do
    {:noreply, maybe_update_firmware(response, %{state | update_reschedule_timer: nil})}
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _, reason}, state) do
    Logger.error("HTTP Streaming Error: #{inspect(reason)}")
    _ = Client.handle_error(reason)
    DeviceChannel.send_update_status("update failed")
    {:noreply, %{state | status: :update_failed}}
  end

  defp maybe_update_firmware(_data, %{status: {:updating, _percent}} = state) do
    # Received an update message from NervesHub, but we're already in progress.
    # It could be because the deployment/device was edited making a duplicate
    # update message or a new deployment was created. Either way, lets not
    # interrupt FWUP and let the task finish. After update and reboot, the
    # device will check-in and get an update message if it was actually new and
    # required
    state
  end

  defp maybe_update_firmware(%{"firmware_url" => url} = data, state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    case Client.update_available(data) do
      :apply ->
        {:ok, http} = HTTPFwupStream.start(self())
        spawn_monitor(HTTPFwupStream, :get, [http, url])
        Logger.info("[NervesHubLink] Downloading firmware: #{url}")
        %{state | status: {:updating, 0}}

      :ignore ->
        state

      {:reschedule, ms} ->
        timer = Process.send_after(self(), {:update_reschedule, data}, ms)
        Logger.info("[NervesHubLink] rescheduling firmware update in #{ms} milliseconds")
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  defp maybe_update_firmware(_, state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    if Process.read_timer(timer) do
      Process.cancel_timer(timer)
    end

    %{state | update_reschedule_timer: nil}
  end
end
