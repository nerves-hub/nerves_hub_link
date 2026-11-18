# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Metrics.Sampler do
  @moduledoc """
  Takes the device's readings, and holds them until the extension sends them.

  Runs from application start rather than from the extension being attached,
  which is what lets a report carry a minute-by-minute history rather than the
  instant it was sent, and what lets a device that spent an hour offline still
  say what it measured while it was gone.

  ## The bound

  A device samples whether or not anything is collecting the samples, so this
  holds `max_samples` of them and drops the oldest past that. The default of
  sixty is also what one message may carry, so a device asked for a report
  hands over everything it has in one go.

  ## Time

  A sample is taken against the monotonic clock, and is given a wall-clock time
  only when it is read back. A device that boots hours behind and syncs NTP a
  minute later would otherwise stamp its first readings with whatever its clock
  said at the time, and NervesHub throws away a reading more than a day from
  its own clock. Converting at the end means those readings arrive dated from a
  clock that has since been corrected.

  ## Configuration

      config :nerves_hub_link,
        metrics: [
          sample_interval_seconds: 60,
          max_samples: 60
        ]

  What is sampled is `NervesHubLink.Metrics`'s.
  """

  use GenServer

  alias NervesHubLink.Metrics

  require Logger

  @default_interval_seconds 60
  @default_max_samples 60

  @doc """
  Start sampling.

  ## Options

    * `:sample_interval_seconds` - how often to take a reading.
    * `:max_samples` - how many readings to hold before dropping the oldest.

  Both default to the `metrics:` configuration, and then to sixty.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The next readings to send, oldest first, at most `max` of them, as reports.

  Left where they are. Paired with `sent/1` rather than handing them over,
  because a push can fail, and readings taken out of here and then not sent are
  gone for good.

  Answers with none when nothing is sampling, which is every device that hasn't
  turned the metrics extension on.
  """
  @spec take(pos_integer()) :: [%{String.t() => term()}]
  def take(max) when is_integer(max) and max > 0 do
    case Process.whereis(__MODULE__) do
      nil -> []
      sampler -> GenServer.call(sampler, {:take, max})
    end
  end

  @doc """
  Forget the first `count` readings `take/1` returned, now that they have gone.
  """
  @spec sent(non_neg_integer()) :: :ok
  def sent(0), do: :ok

  def sent(count) when is_integer(count) and count > 0 do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      sampler -> GenServer.cast(sampler, {:sent, count})
    end
  end

  @doc """
  Take a reading now, rather than waiting for the next one.

  ## Examples

      iex> NervesHubLink.Metrics.Sampler.sample()
      :ok

  """
  @spec sample() :: :ok
  def sample() do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      sampler -> GenServer.call(sampler, :sample)
    end
  end

  @doc "How many readings are waiting."
  @spec count() :: non_neg_integer()
  def count() do
    case Process.whereis(__MODULE__) do
      nil -> 0
      sampler -> GenServer.call(sampler, :count)
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      samples: :queue.new(),
      held: 0,
      max_samples: Keyword.get_lazy(opts, :max_samples, &max_samples/0),
      interval:
        Keyword.get_lazy(opts, :sample_interval_seconds, &interval_seconds/0) |> :timer.seconds()
    }

    # A first reading now rather than one interval from now, so a device asked
    # for a report shortly after it boots has something to say.
    {:ok, state, {:continue, :sample}}
  end

  @impl GenServer
  def handle_continue(:sample, state) do
    {:noreply, state |> take_sample() |> schedule()}
  end

  @impl GenServer
  def handle_call({:take, max}, _from, state) do
    {:reply, reports(state, max), state}
  end

  def handle_call(:sample, _from, state) do
    {:reply, :ok, take_sample(state)}
  end

  def handle_call(:count, _from, state) do
    {:reply, state.held, state}
  end

  @impl GenServer
  def handle_cast({:sent, count}, state) do
    {:noreply, forget(state, count)}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    {:noreply, state |> take_sample() |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    _ = Process.send_after(self(), :sample, state.interval)

    state
  end

  defp take_sample(state) do
    case Metrics.sample() do
      metrics when map_size(metrics) == 0 ->
        state

      metrics ->
        hold(state, %{at: System.monotonic_time(), metrics: metrics})
    end
  catch
    kind, reason ->
      # A metric set that reads a sensor can fail the way the sensor does.
      # Losing the reading is the whole cost: the next one is a minute away,
      # and a device that stopped reporting because one set misbehaved would be
      # harder to diagnose than a gap in a chart.
      Logger.warning(
        "[#{inspect(__MODULE__)}] a reading could not be taken (#{inspect(kind)} : #{inspect(reason)})"
      )

      state
  end

  defp hold(state, sample) do
    state = %{state | samples: :queue.in(sample, state.samples), held: state.held + 1}

    if state.held > state.max_samples do
      {{:value, _oldest}, samples} = :queue.out(state.samples)
      %{state | samples: samples, held: state.held - 1}
    else
      state
    end
  end

  # One reference pair for the whole batch, so readings taken a second apart
  # are still a second apart once they carry a wall-clock time.
  defp reports(state, max) do
    reference = {System.monotonic_time(), DateTime.utc_now()}

    state.samples
    |> :queue.to_list()
    |> Enum.take(max)
    |> Enum.map(fn %{at: at, metrics: metrics} ->
      %{"timestamp" => at |> to_utc(reference) |> DateTime.to_iso8601(), "metrics" => metrics}
    end)
  end

  defp to_utc(at, {monotonic_now, utc_now}) do
    elapsed = System.convert_time_unit(monotonic_now - at, :native, :microsecond)
    DateTime.add(utc_now, -elapsed, :microsecond)
  end

  defp forget(state, count) do
    Enum.reduce(1..count//1, state, fn _, state ->
      case :queue.out(state.samples) do
        {{:value, _sample}, samples} -> %{state | samples: samples, held: state.held - 1}
        {:empty, _samples} -> state
      end
    end)
  end

  defp interval_seconds() do
    case Keyword.get(config(), :sample_interval_seconds, @default_interval_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _not_a_positive_number -> @default_interval_seconds
    end
  end

  defp max_samples() do
    case Keyword.get(config(), :max_samples, @default_max_samples) do
      samples when is_integer(samples) and samples > 0 -> samples
      _not_a_positive_number -> @default_max_samples
    end
  end

  defp config(), do: Application.get_env(:nerves_hub_link, :metrics, [])
end
