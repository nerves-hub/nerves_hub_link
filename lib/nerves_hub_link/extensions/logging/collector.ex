# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.Collector do
  @moduledoc """
  Holds the device's log lines until the Logging extension sends them.

  Runs from application start, not from the extension being attached. Lines
  written while a device is booting, or while it is offline, or while NervesHub
  is still deciding whether it wants logging at all, are the ones an operator
  goes looking for, and none of them exist by the time the extension starts.

  ## The bound

  A device can write faster than a minute's worth of lines can be sent, and a
  device the platform never attaches keeps writing regardless. So this holds a
  fixed number of lines and drops the oldest past it, counting what went. The
  count goes out as a line of its own ahead of the survivors, because a gap
  someone can see beats a gap they cannot.

  ## Where the lines come from

  A `:logger` handler, which runs in the process doing the logging. Everything
  it does is a `send/2` to this process, since anything slower would charge the
  application for the reporting, and anything that logs would recurse.
  """

  use GenServer

  alias NervesHubLink.Extensions.Logging.Config
  alias NervesHubLink.Extensions.Logging.Line

  @handler_id :nerves_hub_link_logging

  @doc """
  Start collecting.

  ## Options

    * `:max_lines` - how many lines to hold. Defaults to what
      `NervesHubLink.Extensions.Logging.Config.max_lines/0` reports.
    * `:level` - the lowest level to collect, as `Logger` names it. Defaults to
      `:info`. Filtering happens in `:logger`, so a line below this costs the
      application nothing.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The next lines to send, oldest first, at most `max` of them.

  Left where they are. Paired with `sent/1` rather than handing them over,
  because a push can fail and lines taken out of here and then not sent are
  exactly what this exists to prevent.
  """
  @spec take(pos_integer()) :: [map()]
  def take(max) when is_integer(max) and max > 0 do
    GenServer.call(__MODULE__, {:take, max})
  end

  @doc """
  Forget the first `count` lines `take/1` returned, now that they have gone.
  """
  @spec sent(non_neg_integer()) :: :ok
  def sent(0), do: :ok

  def sent(count) when is_integer(count) and count > 0,
    do: GenServer.cast(__MODULE__, {:sent, count})

  @doc "How many lines are waiting, the drop notice included."
  @spec count() :: non_neg_integer()
  def count(), do: GenServer.call(__MODULE__, :count)

  @doc false
  @spec collect(map()) :: :ok
  def collect(line) do
    _ = send(__MODULE__, {:line, line})
    :ok
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    :ok = attach_handler(Keyword.get(opts, :level, :info))

    {:ok,
     %{
       lines: :queue.new(),
       held: 0,
       max_lines: Keyword.get(opts, :max_lines, Config.max_lines()),
       dropped: 0,
       gap_opened: nil
     }}
  end

  @impl GenServer
  def handle_call({:take, max}, _from, state) do
    {:reply, batch(state, max), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, state.held + if(state.dropped > 0, do: 1, else: 0), state}
  end

  @impl GenServer
  def handle_cast({:sent, count}, state) do
    {:noreply, forget(state, count)}
  end

  @impl GenServer
  def handle_info({:line, line}, state) do
    {:noreply, hold(state, line)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  defp attach_handler(level) do
    _ = :logger.remove_handler(@handler_id)

    :logger.add_handler(@handler_id, NervesHubLink.Extensions.Logging.Handler, %{
      level: level,
      # Nothing is formatted here. The line is built in the logging process and
      # sent as data, so the collector never has to render anything and the
      # application never waits on it.
      config: %{}
    })
  end

  defp hold(state, line) do
    state = %{state | lines: :queue.in(line, state.lines), held: state.held + 1}

    if state.held > state.max_lines do
      {_dropped, lines} = :queue.out(state.lines)

      %{
        state
        | lines: lines,
          held: state.held - 1,
          dropped: state.dropped + 1,
          gap_opened: state.gap_opened || Line.now()
      }
    else
      state
    end
  end

  defp batch(state, max) do
    notice =
      if state.dropped > 0 do
        [Line.dropped_notice(state.dropped, state.gap_opened)]
      else
        []
      end

    lines =
      state.lines
      |> :queue.to_list()
      |> Enum.take(max - length(notice))

    notice ++ lines
  end

  defp forget(state, count) do
    {count, state} =
      if state.dropped > 0 and count > 0 do
        {count - 1, %{state | dropped: 0, gap_opened: nil}}
      else
        {count, state}
      end

    Enum.reduce(1..count//1, state, fn _, state ->
      case :queue.out(state.lines) do
        {{:value, _line}, lines} -> %{state | lines: lines, held: state.held - 1}
        {:empty, _lines} -> state
      end
    end)
  end
end
