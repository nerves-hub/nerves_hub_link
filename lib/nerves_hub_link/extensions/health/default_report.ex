defmodule NervesHubLink.Extensions.Health.DefaultReport do
  @moduledoc """
  A default health report implementation with support for easily adding
  new metadata, metrics and such via config.
  """
  @behaviour NervesHubLink.Extensions.Health.Report
  alias NervesHubLink.Extensions.Health.Report
  require Logger

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
    case :alarm_handler.get_alarms() do
      alarms when is_list(alarms) ->
        for {id, description} <- alarms, into: %{}, do: {inspect(id), inspect(description)}

      err ->
        %{"NervesHubLink.AlarmReportFailed" => inspect(err)}
    end
  end

  @impl Report
  def metrics do
    [
      metrics_from_config(),
      cpu_temperature(),
      cpu_utilization(),
      load_averages(),
      memory(),
      disk()
    ]
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @impl Report
  def checks do
    checks_from_config()
  end

  @impl Report
  def connectivity do
    [
      connectivity_from_config(),
      vintage_net()
    ]
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp vof({mod, fun, args}), do: apply(mod, fun, args)
  defp vof(val), do: val

  defp get_health_config(key, default) do
    config = Application.get_env(:nerves_hub_link, :health, [])
    Keyword.get(config, key, default)
  end

  defp metadata_from_config do
    metadata = get_health_config(:metadata, %{})

    for {key, val_or_fun} <- metadata, into: %{} do
      {inspect(key), vof(val_or_fun)}
    end
  end

  defp metrics_from_config do
    metrics = get_health_config(:metrics, %{})

    for {key, val_or_fun} <- metrics, into: %{} do
      {inspect(key), vof(val_or_fun)}
    end
  end

  defp checks_from_config do
    checks = get_health_config(:checks, %{})

    for {key, val_or_fun} <- checks, into: %{} do
      {inspect(key), vof(val_or_fun)}
    end
  end

  defp connectivity_from_config do
    connectivity = get_health_config(:connectivity, %{})

    for {key, val_or_fun} <- connectivity, into: %{} do
      {inspect(key), vof(val_or_fun)}
    end
  end

  @default_temperature_source "/sys/class/thermal/thermal_zone0/temp"
  defp cpu_temperature do
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

  defp cpu_utilization do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        cpu_util()

      {:error, {:already_started, _}} ->
        cpu_util()

      _ ->
        %{}
    end
  end

  defp cpu_util do
    case :cpu_sup.util([]) do
      {:all, usage, _, _} ->
        %{cpu_usage_percent: usage}

      _ ->
        %{}
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

    %{mem_size_mb: size_mb, mem_used_mb: used_mb, mem_used_percent: used_percent}
  rescue
    _ ->
      %{}
  end

  defp disk do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        disk_info()

      {:error, {:already_started, _}} ->
        disk_info()

      _ ->
        %{}
    end
  end

  defp disk_info do
    data =
      Enum.find(:disksup.get_disk_info(), fn {key, _, _, _} ->
        key == ~c"/root"
      end)

    case data do
      nil ->
        %{}

      {_, total_kb, available_kb, capacity_percentage} ->
        %{
          disk_total_kb: total_kb,
          disk_available_kb: available_kb,
          disk_used_percentage: capacity_percentage
        }
    end
  end

  def vintage_net() do
    case Application.ensure_loaded(:vintage_net) do
      :ok ->
        ifs = VintageNet.all_interfaces() |> Enum.reject(&(&1 == "lo"))

        PropertyTable.get_all(VintageNet)
        |> Enum.reduce(%{}, fn {key, value}, acc ->
          # Get all data from nuisance PropertyTable structure
          case key do
            ["interface", interface, subkey] ->
              if interface in ifs do
                kv =
                  acc
                  |> Map.get(interface, %{})
                  |> Map.put(subkey, value)

                Map.put(acc, interface, kv)
              else
                acc
              end

            _ ->
              acc
          end
        end)
        |> Enum.reduce(%{}, fn {interface, kv}, acc ->
          case kv do
            %{
              "type" => type,
              "present" => present,
              "state" => state,
              "connection" => connection_status
            } ->
              Map.put(acc, interface, %{
                type: vintage_net_type(type),
                present: present,
                state: state,
                connection_status: connection_status,
                metrics: %{},
                metadata: %{}
              })

            _ ->
              acc
          end
        end)

      {:error, _} ->
        # Probably VintageNet doesn't exist
        %{}
    end
  end

  defp vintage_net_type(VintageNetWiFi), do: :wifi
  defp vintage_net_type(VintageNetEthernet), do: :ethernet
  defp vintage_net_type(VintageNetQMI), do: :mobile
  defp vintage_net_type(VintageNetMobile), do: :mobile
  defp vintage_net_type(_), do: :unknown
end
