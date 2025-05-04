# Extensions: Geo, Health, and Logging

Extensions are pieces of non-critical functionality going over the NervesHub WebSocket. They are separated out under the Extensions mechanism so that the client can happily ignore anything extension-related in service of keeping firmware updates healthy. That is always the top priority.

There are currently three extensions:

- **Geo** provides GeoIP information and allows slotting in a better source.
- **Health** reports device metrics, alarms, metadata and similar.
- **Logging** provides the ability to send and store logs on NervesHub.

Your NervesHub server controls enabling and disabling extensions to allow you to switch them off if they impact operations.

## Geolocation

It is intended to be easy to replace the default Geo Resolver with your own. Maybe you have a GPS module or can resolve a reasonably precise location via LTE. Just change config:

```elixir
config :nerves_hub_link,
  geo: [
    resolver: CatCounter.MyResolver
  ]
```

Your module only needs to implement a single function, see `NervesHubLink.Extensions.Geo.Resolver` for details.

## Health

You can add your own metrics, metadata and alarms.

The default set of metrics used by the `Health.DefaultReport` are:

- `NervesHubLink.Extensions.Health.MetricSet.CPU` - CPU temperature, usage (percentage), and load averages.
- `NervesHubLink.Extensions.Health.MetricSet.Memory` - Memory size (MB), used (MB), and percentage used.
- `NervesHubLink.Extensions.Health.MetricSet.Disk` - Disk size (KB), available (KB), and percentage used.

And one optional metric set:
- `NervesHubLink.Extensions.Health.MetricSet.NetworkTraffic` - Total bytes sent and received (per interface).

You can also create your own metric sets by implementing the `NervesHubLink.Extensions.Health.MetricSet`
behaviour.

If a library you are using provides a metric set, you can add it to the list of metrics, but please ensure
to include all the metric sets you want to use. If you want to include the full default set, you can use
`:default` or `:defaults` in your metric set list.

eg.

```elixir
config :nerves_hub_link,
  health: [
    metric_sets: [
      :defaults,
      MyApp.HealthMetrics,
      ALibrary.BatteryMetrics
    ]
  ]
```

If you only want to use some of the default metrics, you can specify them explicitly:

```elixir
config :nerves_hub_link,
  health: [
    metric_sets: [
      NervesHubLink.Extensions.Health.MetricSet.CPU,
      NervesHubLink.Extensions.Health.MetricSet.Memory
      # the disk metrics have been excluded
    ]
  ]
```

And if you don't want to use any metric sets, you can set the `metric_sets` option to an empty list.

```elixir
config :nerves_hub_link,
  health: [
    metric_sets: []
  ]
```

If you want to add custom metadata to the default health report, you can specify it with:

```elixir
config :nerves_hub_link,
  health: [
    # metadata is added with a key and MFA
    # the function should return a string
    metadata: %{
      "placement" => {CatCounter, :venue, []}
    }
  ]
```

Or you can implement a completely custom reporting module by implementing `NervesHubLink.Extensions.Health.Report` and configuring it:

```elixir
config :nerves_hub_link,
  health: [
    report: CatCounter.MyHealthReport
  ]
```

### Alarms

The [default health report](`NervesHubLink.Extensions.Health.DefaultReport`) uses `:alarm_handler`, but we
recommend the [`alarmist`](https://hex.pm/packages/alarmist) library for improved alarms handling.

## Logging

The Logging extension is responsible for sending logs to the NervesHub platform.

This extension is disabled by default while in Early Release.

You can enable the extension by explicitly defining the `extension_modules` option and including the `NervesHubLink.Extensions.Logging` module in the list:

```elixir
config :nerves_hub_link,
  extension_modules: [
    NervesHubLink.Extensions.Geo,
    NervesHubLink.Extensions.Health,
    NervesHubLink.Extensions.Logging
  ]
```
