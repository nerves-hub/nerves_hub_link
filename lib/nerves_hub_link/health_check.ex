defmodule NervesHubLink.HealthCheck do
    @moduledoc """

    """

    alias Nerves.Runtime.KV

    require Logger

    def default_config do
        # TODO: Default to using your configured NervesMOTD.Runtime
        # TODO: Reshape as a behaviour
        %{
            device_id: {Nerves.Runtime, :serial_number, []},
            timestamp: fn ->
                DateTime.utc_now()
                |> DateTime.to_iso8601()
            end,
            metadata: %{
                "arch" => KV.get_active("nerves_fw_architecture"),
                "platform" => KV.get_active("nerves_fw_platform"),
                "product" => KV.get_active("nerves_fw_product"),
                "version" => KV.get_active("nerves_fw_version"),
                "uuid" => KV.get_active("nerves_fw_uuid"),
            },
            alarms: fn ->
                :alarm_handler.get_alarms()
                |> Enum.map(fn {id, description} ->
                    try
                        {inspect(id), inspect(description)}
                    catch
                        _, _ ->
                            {"bad alarm term", ""}
                    end
                end)
                |> Map.new()
            end,
            metrics: {NervesHubLink.HealthCheck, :default_metrics, []},
            peripherals: {NervesHubLink.HealthCheck, :default_networking, []}
        }
    end

    def run_check(config) do
        %{
            device_id: run(config.device_id),
            timestamp: run(config.timestamp),
            metadata: 
        }
    end

    defp run(fun) when is_function(fun), do: fun.()
    defp run({mod, fun, args}), do: apply(mod, fun, args)


    def default_metrics do
        # TODO: We should reimplement most of how NervesMOTD fetches this stuff in a way that is efficient for this
        # TODO: Ensure stuff is number-shaped
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

        report
    end

    def default_networking do
        VintageNet.all_interfaces()
        |> Enum.map(fn ifname ->
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
        end)
        |> Map.new()
    end
end