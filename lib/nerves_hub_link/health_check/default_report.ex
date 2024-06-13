defmodule NervesHubLink.HealthCheck.DefaultReport do
  alias NervesHubLink.HealthCheck.Report
  require Logger
  @behaviour NervesHubLink.HealthCheck.Report

  @impl Report
  def timestamp do
    DateTime.utc_now()
  end

  @impl Report
  def metadata do
    # A lot of typical metadata is included in the join
    # we can skip that here
    # NervesHub is responsible for joining that into the stored data
    metadata_from_config()
  end

  @impl Report
  def alarms do
    for {id, description} <- :alarm_handler.get_alarms(), into: %{} do
      try do
        {inspect(id), inspect(description)}
      catch
        _, _ ->
          {"bad alarm term", ""}
      end
    end
  end

  @impl Report
  def metrics do
    [
      metrics_from_config(),
      cpu_temperature(),
      load_averages(),
      memory()
    ]
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @impl Report
  def peripherals do
    peripherals_from_config()
  end

  defp vof({mod, fun, args}), do: apply(mod, fun, args)
  defp vof(val), do: val

  defp metadata_from_config do
    case Application.get_env(:nerves_hub_link, :health, [])[:metadata] do
      nil ->
        %{}

      metadata ->
        for {key, val_or_fun} <- metadata, into: %{} do
          {inspect(key), vof(val_or_fun)}
        end
    end
  end

  defp metrics_from_config do
    case Application.get_env(:nerves_hub_link, :health, [])[:metrics] do
      nil ->
        %{}

      metrics ->
        for {key, val_or_fun} <- metrics, into: %{} do
          {inspect(key), vof(val_or_fun)}
        end
    end
  end

  defp peripherals_from_config do
    case Application.get_env(:nerves_hub_link, :health, [])[:peripherals] do
      nil ->
        %{}

      peripherals ->
        for {key, val_or_fun} <- peripherals, into: %{} do
          {inspect(key), vof(val_or_fun)}
        end
    end
  end

  defp cpu_temperature do
    with {:ok, content} <- File.read("/sys/class/thermal/thermal_zone0/temp"),
         {millidegree_c, _} <- Integer.parse(content) do
      %{cpu_temp: millidegree_c / 1000}
    else
      _ -> cpu_temperature_rpi()
    end
  end

  defp cpu_temperature_rpi do
    with {result, 0} <- System.cmd("/usr/bin/vcgencmd", ["measure_temp"]) do
      %{"temp" => temp} = Regex.named_captures(~r/temp=(?<temp>[\d.]+)/, result)
      {temp, _} = Integer.parse(temp)
      %{cpu_temp: temp}
    else
      _ -> %{}
    end
  end

  defp load_averages do
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

  defp memory do
    {free_output, 0} = System.cmd("free", [])
    [_title_row, memory_row | _] = String.split(free_output, "\n")
    [_title_column | memory_columns] = String.split(memory_row)
    [size_kb, used_kb, _, _, _, _] = Enum.map(memory_columns, &String.to_integer/1)
    size_mb = round(size_kb / 1000)
    used_mb = round(used_kb / 1000)
    used_percent = round(used_mb / size_mb * 100)

    %{size_mb: size_mb, used_mb: used_mb, used_percent: used_percent}
  end
end
