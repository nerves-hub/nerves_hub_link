# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Alarms do
  @moduledoc """
  A slim adapter for `Alarmist` and `:alarm_handler`, providing a unified interface for setting and clearing alarms.

  This primarily exists because `:alarm_handler.get_alarms()` will fail if the default alarm_handler
  has been replaced. Until a path is decided for account for that, this keeps the implementations
  separate with minimal set/clear handling adjustment when the default handler is used in order to
  match Alarmist experience better.

  It is also where alarms are watched from, for `NervesHubLink.Extensions.Alarms`:
  `current_alarms/0` says what is set and since when, and `subscribe/0` and
  `change/1` say what changes. With `Alarmist` both come from Alarmist itself.
  Without it they come from `NervesHubLink.Alarms.Tracker`, which watches
  `:alarm_handler` from application start.

  Times are monotonic (`System.monotonic_time/0`, native units) rather than
  wall-clock, and are converted when they are sent. An alarm raised during
  boot, before the clock was set, is then still dated correctly once it has
  been.
  """

  # Only the branch without Alarmist below uses it.
  alias NervesHubLink.Alarms.Tracker, warn: false

  @typedoc """
  An alarm currently set: its id, its description, and the monotonic time it
  was set at, or `nil` when that is not known.
  """
  @type timed_alarm() :: {id :: term(), description :: term(), set_at :: integer() | nil}

  @typedoc """
  One alarm changing, as `change/1` reads a message `subscribe/0` delivered.
  `at` is a monotonic time.
  """
  @type change() :: {:set | :clear, id :: term(), description :: term(), at :: integer()}

  if Code.ensure_loaded?(Alarmist) do
    @spec get_alarms() :: [Alarmist.alarm()]
    def get_alarms(), do: Alarmist.get_alarms()

    @spec clear_alarm(term()) :: :ok
    def clear_alarm(alarm), do: :alarm_handler.clear_alarm(alarm)

    @spec set_alarm({term(), term()}) :: :ok
    def set_alarm(alarm), do: :alarm_handler.set_alarm(alarm)

    @doc """
    Every alarm currently set, with the time it was set at.

    Alarmist records when each alarm last changed, which for a set alarm is
    when it was set. Alarms set before Alarmist started all share its start
    time.
    """
    @spec current_alarms() :: [timed_alarm()]
    def current_alarms() do
      for {id, description} <- Alarmist.get_alarms(), do: {id, description, set_at(id)}
    end

    defp set_at(id) do
      case PropertyTable.fetch_with_timestamp(Alarmist, id) do
        {:ok, _value, timestamp} -> timestamp
        :error -> nil
      end
    end

    @doc """
    Deliver alarm changes to the calling process. Read each message with
    `change/1`.
    """
    @spec subscribe() :: :ok
    def subscribe(), do: Alarmist.subscribe_all()

    @doc """
    Read a message delivered after `subscribe/0`, or `:ignore` for anything
    else.

    Alarms below `:info` are ignored as they are set, for the reason
    `Alarmist.get_alarms/1` leaves them out by default.
    """
    @spec change(term()) :: change() | :ignore
    def change(%Alarmist.Event{state: :set} = event) do
      if Logger.compare_levels(event.level || :warning, :info) == :lt do
        :ignore
      else
        {:set, event.id, event.description, event.timestamp}
      end
    end

    def change(%Alarmist.Event{state: :clear} = event),
      do: {:clear, event.id, nil, event.timestamp}

    def change(_message), do: :ignore
  else
    @spec get_alarms() :: [{term(), term()}]
    def get_alarms(), do: :alarm_handler.get_alarms()

    @spec clear_alarm(term()) :: :ok
    def clear_alarm(alarm) do
      get_alarms()
      |> Enum.filter(&(elem(&1, 0) == alarm))
      |> Enum.each(fn _ -> :alarm_handler.clear_alarm(alarm) end)

      :ok
    end

    @spec set_alarm({term(), term()}) :: :ok
    def set_alarm({mod, _} = alarm) do
      if Enum.any?(:alarm_handler.get_alarms(), &(elem(&1, 0) == mod)) do
        :ok
      else
        :alarm_handler.set_alarm(alarm)
      end
    end

    @doc """
    Every alarm currently set, with the time it was set at.

    Known for anything set after `NervesHubLink.Alarms.Tracker` started, which
    is early in application start; `nil` for anything set before.
    """
    @spec current_alarms() :: [timed_alarm()]
    def current_alarms(), do: Tracker.current_alarms()

    @doc """
    Deliver alarm changes to the calling process. Read each message with
    `change/1`.
    """
    @spec subscribe() :: :ok
    def subscribe(), do: Tracker.subscribe(self())

    @doc """
    Read a message delivered after `subscribe/0`, or `:ignore` for anything
    else.
    """
    @spec change(term()) :: change() | :ignore
    def change(message), do: Tracker.change(message)
  end

  @doc """
  The name an alarm is reported to NervesHub under.

  `inspect/1` of its id, which is what `NervesHubLink.Extensions.Health` has
  always sent. The alarms extension has to name alarms the same way: a device
  that moved from one to the other would otherwise see every alarm it had
  raised cleared and raised again under a new name.
  """
  @spec name(term()) :: String.t()
  def name(id) do
    inspect(id)
  catch
    _, _ -> "bad alarm term"
  end

  @doc """
  Whether an alarm is sent to NervesHub at all.

  Disk-full alarms for the mounts in `health: [alarms: [ignore_disk_full_mounts:
  mounts]]` are not (`["/"]` by default). The alarms extension honours the same
  setting as health, so moving between them does not change what is reported.
  """
  @spec reportable?(term()) :: boolean()
  def reportable?(id), do: id not in ignored_ids()

  @doc """
  The wall-clock time of a monotonic time from `current_alarms/0` or
  `change/1`.

  Worked out from how long ago it was, against the wall clock now, rather
  than read off the wall clock at the time. The monotonic clock has been
  steady all along, so this is right even for an alarm set before the wall
  clock was, provided the wall clock is right now.

  `reference` is `{monotonic, utc}` taken at the same moment, and defaults to
  now.

  ## Examples

      iex> now = System.monotonic_time()
      iex> a_second_ago = now - System.convert_time_unit(1, :second, :native)
      iex> NervesHubLink.Alarms.to_utc(a_second_ago, {now, ~U[2026-09-24 12:00:00.000000Z]})
      ~U[2026-09-24 11:59:59.000000Z]

  """
  @spec to_utc(integer(), {integer(), DateTime.t()}) :: DateTime.t()
  def to_utc(at, {monotonic_now, utc_now} \\ {System.monotonic_time(), DateTime.utc_now()}) do
    elapsed = System.convert_time_unit(monotonic_now - at, :native, :microsecond)
    DateTime.add(utc_now, -elapsed, :microsecond)
  end

  defp ignored_ids() do
    Application.get_env(:nerves_hub_link, :health, [])
    |> Keyword.get(:alarms, [])
    |> Keyword.get(:ignore_disk_full_mounts, ["/"])
    |> Enum.map(fn mount -> {:disk_almost_full, to_charlist(mount)} end)
  end
end
