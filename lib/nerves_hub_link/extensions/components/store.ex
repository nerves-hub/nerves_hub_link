# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components.Store do
  @moduledoc false

  # Holds what the device knows about its components, and sends it.
  #
  # Runs from application start rather than from the extension being attached.
  # An application describes its components when it finds them, usually at
  # boot, and that is long before NervesHub has decided it wants them. So the
  # set has to be somewhere to be answered from when it does.
  #
  # Everything here arrives already checked (see `Component`, `Reading` and
  # `StateChange`), so what is held is exactly what goes on the wire.
  #
  # ## What is sent when
  #
  #   * A snapshot answers every `components:sync`, straight away.
  #   * A change to the set sends one five seconds after the last change, so
  #     pairing twenty sensors in a row sends one snapshot rather than twenty.
  #     A set that never stops changing still goes out every thirty seconds.
  #   * Readings go out at most once a second, 60 reports a message.
  #   * A state change goes out straight away.
  #
  # A reading or state change is only sent for a component NervesHub has been
  # sent in a snapshot. NervesHub ignores one for a component it hasn't heard
  # of, and asks for the set again, so sending it any sooner loses it and
  # spends a sync. Readings wait in the buffer for the snapshot. A state change
  # doesn't need to: the snapshot carries the component's state.

  use GenServer

  alias NervesHubLink.Extensions.Components
  alias NervesHubLink.Extensions.Components.Component
  alias NervesHubLink.Extensions.Components.Config

  require Logger

  @max_components 500
  @max_reports_per_message 60

  @snapshot_delay_ms 5_000
  @snapshot_max_delay_ms 30_000
  @readings_interval_ms 1_000

  @doc false
  @spec max_components() :: 500
  def max_components(), do: @max_components

  @doc """
  Start the store.

  ## Options

    * `:max_readings` - how many readings to hold. Defaults to
      `NervesHubLink.Extensions.Components.Config.max_readings/0`.

  The delays are options too, so tests needn't wait five seconds a snapshot.
  They are the contract's numbers, and not configuration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Replace the set."
  @spec set([Component.t()]) :: :ok | {:error, :not_running}
  def set(entries), do: call({:set, entries})

  @doc "Add or replace one component."
  @spec put(Component.t()) :: :ok | {:error, :too_many_components | :not_running}
  def put(entry), do: call({:put, entry})

  @doc "Remove one component."
  @spec delete(Component.key()) :: :ok | {:error, :not_running}
  def delete(key), do: call({:delete, key})

  @doc "Record a component's state taking a new value."
  @spec state(map()) ::
          :ok | {:error, :unknown_component | :too_many_states | :not_running}
  def state(frame), do: call({:state, frame})

  @doc """
  Queue one report of readings. A cast, because readings are the one thing an
  application sends often, and it shouldn't wait on the socket to do it.
  """
  @spec readings(map()) :: :ok
  def readings(report), do: GenServer.cast(__MODULE__, {:readings, report})

  @doc "Answer `components:sync`: send the set now."
  @spec answer_sync() :: :ok
  def answer_sync(), do: GenServer.cast(__MODULE__, :answer_sync)

  @doc "The set as it would be sent now."
  @spec components() :: [Component.t()]
  def components() do
    case call(:components) do
      {:error, :not_running} -> []
      components -> components
    end
  end

  # Nothing here can be done without the store, and it isn't running on a
  # device that hasn't configured the extension, or whose supervisor hasn't
  # started yet. A call to a name nobody holds exits, and describing a
  # component shouldn't be able to take the application down.
  defp call(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      store -> GenServer.call(store, message)
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       components: %{},
       # Per component, only once something has said what its state is.
       # Absent is not the same as empty: absent says nothing about state,
       # and leaves what NervesHub has stored alone.
       states: %{},
       # The components in the last snapshot NervesHub accepted from us, which
       # are the ones it will take readings and state changes for.
       sent: MapSet.new(),
       last_sent: nil,
       snapshot_timer: nil,
       changed_since: nil,
       readings: [],
       held: 0,
       next_seq: 0,
       dropped: 0,
       readings_timer: nil,
       readings_sent_at: nil,
       max_readings: Keyword.get_lazy(opts, :max_readings, &Config.max_readings/0),
       snapshot_delay: Keyword.get(opts, :snapshot_delay_ms, @snapshot_delay_ms),
       snapshot_max_delay: Keyword.get(opts, :snapshot_max_delay_ms, @snapshot_max_delay_ms),
       readings_interval: Keyword.get(opts, :readings_interval_ms, @readings_interval_ms)
     }}
  end

  @impl GenServer
  def handle_call({:set, entries}, _from, state) do
    components = Map.new(entries, &{Component.key(&1), Map.delete(&1, "state")})

    # A component listed without `state` keeps what the device last said about
    # it. Only a component that has gone takes its state with it.
    states =
      Enum.reduce(entries, Map.take(state.states, Map.keys(components)), fn entry, states ->
        case entry do
          %{"state" => component_state} -> Map.put(states, Component.key(entry), component_state)
          _no_state -> states
        end
      end)

    {:reply, :ok, update_set(state, components, states)}
  end

  def handle_call({:put, entry}, _from, state) do
    key = Component.key(entry)

    if not Map.has_key?(state.components, key) and map_size(state.components) >= @max_components do
      {:reply, {:error, :too_many_components}, state}
    else
      components = Map.put(state.components, key, Map.delete(entry, "state"))

      states =
        case entry do
          %{"state" => component_state} -> Map.put(state.states, key, component_state)
          _no_state -> state.states
        end

      {:reply, :ok, update_set(state, components, states)}
    end
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok,
     update_set(state, Map.delete(state.components, key), Map.delete(state.states, key))}
  end

  def handle_call({:state, %{"state" => name, "value" => value} = frame}, _from, state) do
    key = Component.key(frame)
    current = Map.get(state.states, key, %{})

    cond do
      not Map.has_key?(state.components, key) ->
        {:reply, {:error, :unknown_component}, state}

      Map.get(current, name) == value ->
        # NervesHub would do nothing with it either.
        {:reply, :ok, state}

      not Map.has_key?(current, name) and map_size(current) >= Component.max_states() ->
        {:reply, {:error, :too_many_states}, state}

      true ->
        state = put_in(state.states[key], Map.put(current, name, value))

        # Sent after replying, so the application isn't kept waiting on the
        # socket. A component NervesHub hasn't been sent yet gets its state
        # in the snapshot that lists it.
        if MapSet.member?(state.sent, key),
          do: {:reply, :ok, state, {:continue, {:push_state, frame}}},
          else: {:reply, :ok, state}
    end
  end

  def handle_call(:components, _from, state) do
    {:reply, snapshot(state)["components"], state}
  end

  @impl GenServer
  def handle_continue({:push_state, frame}, state) do
    # A change that didn't go is corrected by the next snapshot, which carries
    # the state as it is now. The platform sends a sync when it attaches.
    _ = push("state", frame)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:readings, report}, state) do
    key = Component.key(report)

    if Map.has_key?(state.components, key) do
      {:noreply, state |> hold(key, report) |> schedule_readings()}
    else
      {namespace, serial} = key

      Logger.warning(
        "[NervesHubLink.Extensions.Components] dropped readings for #{namespace} #{serial}, " <>
          "which isn't in the component set"
      )

      {:noreply, state}
    end
  end

  def handle_cast(:answer_sync, state) do
    # Whatever is pending is about to go, so the timer has nothing left to do.
    {:noreply, state |> cancel_snapshot() |> send_snapshot()}
  end

  @impl GenServer
  def handle_info({:send_snapshot, timer}, %{snapshot_timer: timer} = state) do
    state = %{state | snapshot_timer: nil, changed_since: nil}

    # Changed and changed back again. NervesHub would compare it with what it
    # has and write nothing, and it costs a token from a small bucket.
    if snapshot(state) == state.last_sent,
      do: {:noreply, state},
      else: {:noreply, send_snapshot(state)}
  end

  def handle_info({:send_readings, timer}, %{readings_timer: timer} = state) do
    {:noreply, send_readings(%{state | readings_timer: nil})}
  end

  # A timer cancelled after it had already fired.
  def handle_info(_message, state), do: {:noreply, state}

  defp update_set(state, components, states) do
    before = snapshot(state)
    state = %{state | components: components, states: states} |> forget_readings()

    if snapshot(state) == before, do: state, else: schedule_snapshot(state)
  end

  defp snapshot(state) do
    components =
      state.components
      |> Enum.sort_by(fn {key, _entry} -> key end)
      |> Enum.map(fn {key, entry} ->
        case Map.fetch(state.states, key) do
          {:ok, component_state} -> Map.put(entry, "state", component_state)
          :error -> entry
        end
      end)

    %{"components" => components}
  end

  defp send_snapshot(state) do
    payload = snapshot(state)

    case push("snapshot", payload) do
      {:ok, _ref} ->
        sent = MapSet.new(state.components, fn {key, _entry} -> key end)

        # The readings held for components NervesHub has just been told about
        # can go now.
        schedule_readings(%{state | sent: sent, last_sent: payload})

      {:error, reason} ->
        # Detached, most likely. NervesHub sends a sync when it attaches, and
        # the answer carries this.
        Logger.debug(
          "[NervesHubLink.Extensions.Components] snapshot not sent: #{inspect(reason)}"
        )

        state
    end
  end

  # Five seconds after the last change, and never more than thirty after the
  # first one that hasn't gone yet.
  defp schedule_snapshot(state) do
    now = System.monotonic_time(:millisecond)
    changed_since = state.changed_since || now
    delay = min(state.snapshot_delay, max(changed_since + state.snapshot_max_delay - now, 0))

    state = cancel_snapshot(state)
    timer = make_ref()
    _ = Process.send_after(self(), {:send_snapshot, timer}, delay)

    %{state | snapshot_timer: timer, changed_since: changed_since}
  end

  # Timers are matched by a reference of our own rather than cancelled with
  # `Process.cancel_timer/1`, which can't take back a message already waiting
  # in the mailbox.
  defp cancel_snapshot(state), do: %{state | snapshot_timer: nil, changed_since: nil}

  defp hold(state, key, report) do
    readings = state.readings ++ [{state.next_seq, key, report}]
    state = %{state | readings: readings, held: state.held + 1, next_seq: state.next_seq + 1}

    if state.held > state.max_readings do
      if state.dropped == 0 do
        Logger.warning(
          "[NervesHubLink.Extensions.Components] holding #{state.max_readings} readings, " <>
            "dropping the oldest until they can be sent"
        )
      end

      %{state | readings: tl(state.readings), held: state.held - 1, dropped: state.dropped + 1}
    else
      state
    end
  end

  # Readings for a component that has left the set would wait for a snapshot
  # that is never going to list it.
  defp forget_readings(state) do
    readings =
      Enum.filter(state.readings, fn {_seq, key, _report} ->
        Map.has_key?(state.components, key)
      end)

    %{state | readings: readings, held: length(readings)}
  end

  defp sendable(state) do
    Enum.filter(state.readings, fn {_seq, key, _report} -> MapSet.member?(state.sent, key) end)
  end

  # At most one message a second. Nothing is scheduled while every reading
  # held is waiting for a snapshot; sending the snapshot schedules them.
  defp schedule_readings(%{readings_timer: nil} = state) do
    if sendable(state) == [] do
      state
    else
      delay =
        case state.readings_sent_at do
          nil ->
            0

          sent_at ->
            max(sent_at + state.readings_interval - System.monotonic_time(:millisecond), 0)
        end

      timer = make_ref()
      _ = Process.send_after(self(), {:send_readings, timer}, delay)
      %{state | readings_timer: timer}
    end
  end

  defp schedule_readings(state), do: state

  defp send_readings(state) do
    case state |> sendable() |> Enum.take(@max_reports_per_message) do
      [] -> state
      batch -> send_batch(state, batch)
    end
  end

  defp send_batch(state, batch) do
    reports = Enum.map(batch, fn {_seq, _key, report} -> report end)

    case push("readings", %{"reports" => reports}) do
      {:ok, _ref} ->
        sent = MapSet.new(batch, fn {seq, _key, _report} -> seq end)

        readings =
          Enum.reject(state.readings, fn {seq, _key, _report} -> MapSet.member?(sent, seq) end)

        state
        |> Map.merge(%{
          readings: readings,
          held: length(readings),
          readings_sent_at: System.monotonic_time(:millisecond)
        })
        |> report_dropped()
        |> schedule_readings()

      {:error, reason} ->
        # Kept, and tried again with the next reading, or once a snapshot has
        # gone. A timer would only spin while the device is detached.
        Logger.debug(
          "[NervesHubLink.Extensions.Components] readings not sent: #{inspect(reason)}"
        )

        state
    end
  end

  defp report_dropped(%{dropped: 0} = state), do: state

  defp report_dropped(state) do
    Logger.warning(
      "[NervesHubLink.Extensions.Components] dropped #{state.dropped} readings that couldn't be sent in time"
    )

    %{state | dropped: 0}
  end

  # Through the extensions process, which refuses anything while the extension
  # is detached. It may not be running at all, and a component update must
  # never take this process down with it.
  defp push(event, payload) do
    Components.push(event, payload)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
