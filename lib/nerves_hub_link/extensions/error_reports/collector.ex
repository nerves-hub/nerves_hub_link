# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports.Collector do
  @moduledoc """
  Holds the device's error reports until the extension sends them.

  Runs from application start, not from the extension being attached. A crash
  during boot is the one an operator most wants, and by the time NervesHub has
  decided it wants error reports at all, it is long gone.

  ## The bound

  A supervisor restart storm produces reports faster than they can be sent, and
  a device the platform never attaches keeps crashing regardless. So this holds
  a fixed number and drops the oldest past it, counting what went. The count
  goes out as a report of its own ahead of the survivors, because a gap someone
  can see beats a gap they cannot.

  ## Where the reports come from

  A `:logger` handler, which runs in the process that crashed. Everything it
  does is a `send/2` to this process: anything slower would charge the
  application for the reporting, and anything that logs would recurse.
  """

  use GenServer

  alias NervesHubLink.Extensions.ErrorReports.Config
  alias NervesHubLink.Extensions.ErrorReports.Report

  @handler_id :nerves_hub_link_error_reports

  @doc """
  Start collecting.

  ## Options

    * `:max_reports` - how many to hold. Defaults to
      `NervesHubLink.Extensions.ErrorReports.Config.max_reports/0`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The next reports to send, oldest first, at most `max` of them.

  Left where they are. Paired with `sent/1` rather than handing them over,
  because a push can fail, and reports taken out of here and then not sent are
  exactly what this exists to prevent.
  """
  @spec take(pos_integer()) :: [Report.t()]
  def take(max) when is_integer(max) and max > 0 do
    GenServer.call(__MODULE__, {:take, max})
  end

  @doc """
  Forget the first `count` reports `take/1` returned, now that they have gone.
  """
  @spec sent(non_neg_integer()) :: :ok
  def sent(0), do: :ok

  def sent(count) when is_integer(count) and count > 0,
    do: GenServer.cast(__MODULE__, {:sent, count})

  @doc "How many reports are waiting, the drop notice included."
  @spec count() :: non_neg_integer()
  def count(), do: GenServer.call(__MODULE__, :count)

  @doc false
  @spec collect(Report.t()) :: :ok
  def collect(report) do
    # Looked up rather than sent to by name: this is called from the process
    # that crashed and from `NervesHubLink.report_error/3`, and on a device
    # that never turned the extension on there is nothing registered under
    # this name. `send/2` to a name nobody holds raises, which would make
    # reporting an error a second error.
    case Process.whereis(__MODULE__) do
      nil -> :ok
      collector -> _ = send(collector, {:report, report})
    end

    :ok
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    :ok = attach_handler()

    {:ok,
     %{
       reports: :queue.new(),
       held: 0,
       max_reports: Keyword.get(opts, :max_reports, Config.max_reports()),
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
  def handle_info({:report, report}, state) do
    {:noreply, hold(state, report)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  # At `:error`, which is where the runtime logs a process dying. The handler
  # still checks for `crash_reason`, so this only saves it being called for
  # every line below error rather than deciding what counts as an error.
  defp attach_handler() do
    _ = :logger.remove_handler(@handler_id)

    :logger.add_handler(@handler_id, NervesHubLink.Extensions.ErrorReports.Handler, %{
      level: :error,
      config: %{}
    })
  end

  defp hold(state, report) do
    state = %{state | reports: :queue.in(report, state.reports), held: state.held + 1}

    if state.held > state.max_reports do
      {_dropped, reports} = :queue.out(state.reports)

      %{
        state
        | reports: reports,
          held: state.held - 1,
          dropped: state.dropped + 1,
          gap_opened: state.gap_opened || Report.now()
      }
    else
      state
    end
  end

  defp batch(state, max) do
    notice =
      if state.dropped > 0 do
        [Report.dropped_notice(state.dropped, state.gap_opened)]
      else
        []
      end

    reports =
      state.reports
      |> :queue.to_list()
      |> Enum.take(max - length(notice))

    notice ++ reports
  end

  defp forget(state, count) do
    {count, state} =
      if state.dropped > 0 and count > 0 do
        {count - 1, %{state | dropped: 0, gap_opened: nil}}
      else
        {count, state}
      end

    Enum.reduce(1..count//1, state, fn _, state ->
      case :queue.out(state.reports) do
        {{:value, _report}, reports} -> %{state | reports: reports, held: state.held - 1}
        {:empty, _reports} -> state
      end
    end)
  end
end
