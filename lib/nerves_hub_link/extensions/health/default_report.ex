defmodule NervesHubLink.Extensions.Health.DefaultReport do
  @moduledoc """
  A default health report implementation with support for easily adding
  new metadata, metrics and such via config.
  """
  @behaviour NervesHubLink.Extensions.Health.Report

  alias NervesHubLink.Extensions.Health.Report

  @default_metric_sets [
    NervesHubLink.Extensions.Health.MetricSet.CPU,
    NervesHubLink.Extensions.Health.MetricSet.Disk,
    NervesHubLink.Extensions.Health.MetricSet.Memory
  ]

  @impl Report
  def timestamp() do
    DateTime.utc_now()
  end

  @impl Report
  def metadata() do
    # A lot of typical metadata is included in the join
    # we can skip that here
    # NervesHub is responsible for joining that into the stored data
    metadata_from_config()
  end

  # Currently, only Alarmist is supported as alarm handler.
  # Send empty map if Alarmist isn't loaded.
  if Code.ensure_loaded?(Alarmist) do
    @impl Report
    def alarms() do
      for {id, description} <- Alarmist.get_alarms(), into: %{} do
        try do
          {inspect(id), inspect(description)}
        catch
          _, _ ->
            {"bad alarm term", ""}
        end
      end
    end
  else
    @impl Report
    def alarms() do
      %{}
    end
  end

  @impl Report
  def metrics() do
    [
      metrics_from_config(),
      get_metric_sets()
    ]
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @impl Report
  def checks() do
    checks_from_config()
  end

  @impl Report
  def connectivity() do
    [
      connectivity_from_config(),
      vintage_net()
    ]
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp get_metric_sets() do
    metric_sets =
      Application.get_env(:nerves_hub_link, :health, [])
      |> Keyword.get(:metric_sets, @default_metric_sets)
      |> Enum.map(fn metric_set ->
        if metric_set in [:default, :defaults] do
          @default_metric_sets
        else
          metric_set
        end
      end)
      |> List.flatten()

    for metric_set <- metric_sets,
        {k, v} <- metric_set.sample(),
        into: %{},
        do: {normalize_key(k), v}
  end

  defp vof({mod, fun, args}), do: apply(mod, fun, args)
  defp vof(val), do: val

  defp get_health_config(key, default) do
    config = Application.get_env(:nerves_hub_link, :health, [])
    Keyword.get(config, key, default)
  end

  defp metadata_from_config() do
    metadata = get_health_config(:metadata, %{})

    for {key, val_or_fun} <- metadata, into: %{} do
      {normalize_key(key), vof(val_or_fun)}
    end
  end

  defp metrics_from_config() do
    metrics = get_health_config(:metrics, %{})

    for {key, val_or_fun} <- metrics, into: %{} do
      {normalize_key(key), vof(val_or_fun)}
    end
  end

  defp checks_from_config() do
    checks = get_health_config(:checks, %{})

    for {key, val_or_fun} <- checks, into: %{} do
      {normalize_key(key), vof(val_or_fun)}
    end
  end

  defp connectivity_from_config() do
    connectivity = get_health_config(:connectivity, %{})

    for {key, val_or_fun} <- connectivity, into: %{} do
      {inspect(key), vof(val_or_fun)}
    end
  end

  defp normalize_key(key) when not is_binary(key) do
    to_string(key)
    |> normalize_key()
  end

  defp normalize_key(key) do
    if String.printable?(key) do
      key
    else
      inspect(key)
    end
  end

  defp vintage_net() do
    case Application.ensure_loaded(:vintage_net) do
      :ok ->
        format_interfaces()

      {:error, _} ->
        # Probably VintageNet doesn't exist
        %{}
    end
  end

  defp format_interfaces() do
    ifs = VintageNet.all_interfaces() |> Enum.reject(&(&1 == "lo"))

    PropertyTable.get_all(VintageNet)
    |> Enum.reduce(%{}, fn
      {["interface", interface, subkey], value}, acc ->
        if interface in ifs do
          kv =
            acc
            |> Map.get(interface, %{})
            |> Map.put(subkey, value)

          Map.put(acc, interface, kv)
        else
          acc
        end

      _, acc ->
        acc
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
  end

  defp vintage_net_type(VintageNetWiFi), do: :wifi
  defp vintage_net_type(VintageNetEthernet), do: :ethernet
  defp vintage_net_type(VintageNetQMI), do: :mobile
  defp vintage_net_type(VintageNetMobile), do: :mobile
  defp vintage_net_type(_), do: :unknown
end
