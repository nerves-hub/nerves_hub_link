# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Alarms.Tracker do
  @moduledoc """
  Watches `:alarm_handler` for devices without `Alarmist`, and remembers when
  each alarm was set.

  `:alarm_handler` keeps which alarms are set but not since when, and tells
  nobody when that changes. Alarmist does both, which is why this only runs
  without it (see `NervesHubLink.Supervisor`). It installs a handler on
  `:alarm_handler` and keeps its own copy of the set, with a monotonic time for
  each alarm.

  It starts with the application rather than with the alarms extension. An
  alarm raised during boot is usually raised before the device has connected,
  so by the time NervesHub attaches the extension the moment has passed, and
  only something already watching could have seen it.

  Alarms set before this starts are still reported, just without a time.
  """

  use GenServer

  require Logger

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Every alarm currently set, with the monotonic time it was set at when this
  saw it happen.

  Falls back to `:alarm_handler` itself, without times, when this is not
  running.
  """
  @spec current_alarms() :: [NervesHubLink.Alarms.timed_alarm()]
  def current_alarms() do
    GenServer.call(__MODULE__, :current_alarms)
  catch
    :exit, _ -> for {id, description} <- alarm_handler_alarms(), do: {id, description, nil}
  end

  @doc """
  Deliver each change to `pid` until it exits. Read the messages with
  `change/1`.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  catch
    :exit, _ ->
      Logger.warning("[NervesHubLink.Alarms.Tracker] not running; alarm changes will not be sent")
      :ok
  end

  @doc "Read a message `subscribe/1` delivered, or `:ignore` for anything else."
  @spec change(term()) :: NervesHubLink.Alarms.change() | :ignore
  def change({__MODULE__, state, id, description, at}) when state in [:set, :clear],
    do: {state, id, description, at}

  def change(_message), do: :ignore

  @impl GenServer
  def init(_opts) do
    # Handler first, then the current set: an alarm set in between is then
    # seen twice, which the map absorbs, rather than not at all.
    case :gen_event.add_sup_handler(:alarm_handler, __MODULE__.Handler, self()) do
      :ok ->
        alarms =
          for {id, description} <- alarm_handler_alarms(), into: %{}, do: {id, {description, nil}}

        {:ok, %{alarms: alarms, subscribers: %{}}}

      error ->
        {:stop, {:cannot_add_handler, error}}
    end
  catch
    # No `:alarm_handler` to watch: SASL is not running. Nothing will ever set
    # an alarm, so there is nothing to track either.
    :exit, reason ->
      Logger.warning(
        "[NervesHubLink.Alarms.Tracker] cannot watch :alarm_handler: #{inspect(reason)}"
      )

      :ignore
  end

  @impl GenServer
  def handle_call(:current_alarms, _from, state) do
    alarms = for {id, {description, at}} <- state.alarms, do: {id, description, at}
    {:reply, alarms, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      if Map.has_key?(state.subscribers, pid),
        do: state.subscribers,
        else: Map.put(state.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_info({:alarm_handler, :set, id, description, at}, state) do
    # A repeat keeps the time of the first: the alarm has been set since then.
    alarms =
      Map.update(state.alarms, id, {description, at}, fn {_old, first_at} ->
        {description, first_at || at}
      end)

    notify(state, :set, id, description, at)
    {:noreply, %{state | alarms: alarms}}
  end

  def handle_info({:alarm_handler, :clear, id, at}, state) do
    notify(state, :clear, id, nil, at)
    {:noreply, %{state | alarms: Map.delete(state.alarms, id)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  # The handler was removed or crashed. Stopping lets the supervisor install a
  # fresh one, and the set is read again from `:alarm_handler` as it does.
  def handle_info({:gen_event_EXIT, _handler, reason}, state) do
    {:stop, {:handler_removed, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp notify(state, change, id, description, at) do
    for pid <- Map.keys(state.subscribers),
        do: send(pid, {__MODULE__, change, id, description, at})

    :ok
  end

  # What `:alarm_handler.get_alarms/0` does, called directly because its spec
  # promises a list. It answers `{:error, :bad_module}` instead when something
  # has replaced `:alarm_handler`'s own handler, which is the only one that
  # knows what is set.
  defp alarm_handler_alarms() do
    case :gen_event.call(:alarm_handler, :alarm_handler, :get_alarms) do
      alarms when is_list(alarms) -> alarms
      _replaced -> []
    end
  catch
    :exit, _ -> []
  end

  defmodule Handler do
    @moduledoc false
    # Runs inside `:alarm_handler`, so it does nothing but stamp the time and
    # pass the event on. Anything slower here would hold up whoever set the
    # alarm.
    @behaviour :gen_event

    @impl :gen_event
    def init(tracker), do: {:ok, tracker}

    @impl :gen_event
    def handle_event({:set_alarm, {id, description}}, tracker) do
      send(tracker, {:alarm_handler, :set, id, description, System.monotonic_time()})
      {:ok, tracker}
    end

    def handle_event({:set_alarm, id}, tracker) do
      send(tracker, {:alarm_handler, :set, id, nil, System.monotonic_time()})
      {:ok, tracker}
    end

    def handle_event({:clear_alarm, id}, tracker) do
      send(tracker, {:alarm_handler, :clear, id, System.monotonic_time()})
      {:ok, tracker}
    end

    def handle_event(_event, tracker), do: {:ok, tracker}

    @impl :gen_event
    def handle_call(_request, tracker), do: {:ok, :ok, tracker}
  end
end
