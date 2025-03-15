defmodule NervesHubLink.Extensions.Health.MetricSet.CPU do
  @moduledoc """
  Health report metrics for CPU temperature, utilization, and load averages.

  The keys used in the report are:
    - cpu_temp: CPU temperature in Celsius
    - cpu_usage_percent: CPU utilization percentage
    - load_1min: Load average over the last minute
    - load_5min: Load average over the last five minutes
    - load_15min: Load average over the last fifteen minutes
  """
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  @impl NervesHubLink.Extensions.Health.MetricSet
  def metrics() do
    [
      cpu_temperature(),
      cpu_utilization(),
      load_averages()
    ]
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @default_temperature_source "/sys/class/thermal/thermal_zone0/temp"
  defp cpu_temperature() do
    cond do
      match?({:ok, _}, File.stat(@default_temperature_source)) ->
        with {:ok, content} <- File.read(@default_temperature_source),
             {millidegree_c, _} <- Integer.parse(content) do
          %{cpu_temp: millidegree_c / 1000}
        else
          _ ->
            %{}
        end

      match?({:ok, _}, File.stat("/usr/bin/vcgencmd")) ->
        cpu_temperature_rpi()

      true ->
        %{}
    end
  end

  defp cpu_utilization() do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        cpu_util()

      {:error, {:already_started, _}} ->
        cpu_util()

      _ ->
        %{}
    end
  end

  defp cpu_util() do
    case :cpu_sup.util([]) do
      {:all, usage, _, _} ->
        %{cpu_usage_percent: usage}

      _ ->
        %{}
    end
  end

  defp cpu_temperature_rpi() do
    case System.cmd("/usr/bin/vcgencmd", ["measure_temp"]) do
      {result, 0} ->
        %{"temp" => temp} = Regex.named_captures(~r/temp=(?<temp>[\d.]+)/, result)
        {temp, _} = Integer.parse(temp)
        %{cpu_temp: temp}

      _ ->
        %{}
    end
  end

  defp load_averages() do
    with {:ok, data_str} <- File.read("/proc/loadavg"),
         [min1, min5, min15, _, _] <- String.split(data_str, " "),
         {min1, _} <- Float.parse(min1),
         {min5, _} <- Float.parse(min5),
         {min15, _} <- Float.parse(min15) do
      %{load_1min: min1, load_5min: min5, load_15min: min15}
    else
      _ -> %{}
    end
  end
end
