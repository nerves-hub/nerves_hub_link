defmodule NervesHubLink.HealthCheck.DefaultReport do
  alias NervesHubLink.HealthCheck.Report
  require Logger
  @behaviour NervesHubLink.HealthCheck.Report

  @impl Report
  def timestamp,
    do:
      DateTime.utc_now()
      |> DateTime.to_iso8601()

  @impl Report
  def metadata do
    # A lot of typical metadata is included in the join
    # we can skip that here
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
    report = %{}

    # TODO: Replace MOTD implementations for direct ones, fewer deps, less err handling
    cpu = NervesMOTD.Runtime.Target.cpu_temperature()

    report =
      case cpu do
        :error ->
          report

        {:ok, val} ->
          Map.put(report, :cpu_temperature, val)
      end

    mem = NervesMOTD.Runtime.Target.memory_stats()

    report =
      case mem do
        :error ->
          Logger.warning("Could not fetch memory stats for health check metrics.")
          report

        {:ok, %{size_mb: size_mb, used_mb: used_mb, used_percent: used_percent}} ->
          Map.merge(report, %{
            memory_size_mb: size_mb,
            memory_used_mb: used_mb,
            memory_used_percent: used_percent
          })
      end

    load = NervesMOTD.Runtime.Target.load_average()

    report =
      case load do
        :error ->
          Logger.warning("Could not fetch load average stats for health check metrics.")
          report

        {:ok, [l1min, l5min, l15min]} ->
          Map.merge(report, %{load_1min: l1min, load_5min: l5min, load_15min: l15min})
      end

    Map.merge(report, metrics_from_config())
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
end
