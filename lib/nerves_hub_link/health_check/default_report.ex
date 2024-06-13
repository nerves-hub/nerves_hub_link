defmodule NervesHubLink.HealthCheck.DefaultReport do
    alias NervesHubLink.HealthCheck.Report
    use NervesHubLink.HealthCheck.Report

    @impl Report
    def device_id, do: Nerves.Runtime.serial_number()
    
    @impl Report
    def timestamp, do:
        DateTime.utc_now()
        |> DateTime.to_iso8601()

    @impl Report
    def metadata do
        # TODO: What else?
        %{
            "arch" => KV.get_active("nerves_fw_architecture"),
            "platform" => KV.get_active("nerves_fw_platform"),
            "product" => KV.get_active("nerves_fw_product"),
            "version" => KV.get_active("nerves_fw_version"),
            "uuid" => KV.get_active("nerves_fw_uuid"),
        }
        |> Map.merge(metadata_from_config())
    end

    @impl Report
    def alarms do
        for {id, description} <- :alarm_handler.get_alarms(), into: %{}, do
            try
                {inspect(id), inspect(description)}
            catch
                _, _ ->
                    {"bad alarm term", ""}
            end
        end
    end

    @impl Report
    def metrics do
        report = 
            %{
                "cpu_temperature" => NervesHubLink.HealthCheck.from_motd(:cpu_temperature),
            }
            mem = NervesMOTD.Runtime.Target.memory_stats()
            report = 
                case mem do
                    :error ->
                        Logger.warning("Could not fetch memory stats for health check metrics.")
                        report
                    {:ok, %{size_mb: size_mb, used_mb: used_mb, used_percent: used_percent}} ->
                        Map.merge(report, %{memory_size_mb: size_mb, memory_used_mb: used_mb, memory_used_percent: used_percent})
    
                end
    
            load = NervesMOTD.Runtime.Target.load_average()
            report =
                case load do
                    :error ->
                        Logger.warning("Could not fetch load average stats for health check metrics.")
                        report
                    {:ok, [1min, 5min, 15min]} ->
                        Map.merge(report, %{load_1min: 1min, load_5min: 5min, load_15min: 15min})
                    end
    
        Map.merge(report, metrics_from_config())
    end

    def peripherals do
        peripherals =
            for ifname <- VintageNet.all_interfaces(), into: %{}, do
                config = VintagetNet.get_configuration(ifname)
                present? = VintageNet.get(["interface", ifname, "present"]) || false
                %{
                    id: ifname,
                    name: ifname,
                    device_type: "network_interface",
                    connection_type: inspect(config[:type] || "unknown"),
                    connection_id: ifname,
                    enabled: present?,
                    # TODO: Add some test
                    tested: false,
                    working: false,
                    errors: []
                }
            end

        Map.merge(peripherals, peripherals_from_config())
    end

    defp vof({mod, fun, args}), do: apply(mod, fun, args)
    defp vof(val), do: val

    defp metadata_from_config do
        case Application.get_env(:nerves_hub_link, :health, [])[:metadata] do
            nil -> %{}
            metadata ->
                for {key, val_or_fun} <- metadata, into: %{} do
                    {inspect(key), vof(val_or_fun)}
                end
        end
    end

    defp metrics_from_config do
        case Application.get_env(:nerves_hub_link, :health, [])[:metrics] do
            nil -> %{}
            metrics ->
                for {key, val_or_fun} <- metrics, into: %{} do
                    {inspect(key), vof(val_or_fun)}
                end
        end
    end

    defp peripherals_from_config do
        case Application.get_env(:nerves_hub_link, :health, [])[:peripherals] do
            nil -> %{}
            peripherals ->
                for {key, val_or_fun} <- peripherals, into: %{} do
                    {inspect(key), vof(val_or_fun)}
                end
        end
    end
end