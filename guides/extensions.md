# Extensions: Health and Geo

Extensions are pieces of non-critical functionality going over the NervesHub WebSocket. They are separated out under the Extensions mechanism so that the client can happily ignore anything extension-related in service of keeping firmware updates healthy. That is always the top priority.

There are two extensions currently:

- **Health** reports device metrics, alarms, metadata and similar.
- **Geo** provides GeoIP information and allows slotting in a better source.

Your NervesHub server controls enabling and disabling extensions to allow you to switch them off if they impact operations.

## Health

You can add your own metrics, metadata and alarms.

The default set of metrics used by the `Health.DefaultReport` are:

- `NervesHubLink.Extensions.Health.MetricSet.CPU` - CPU temperature, usage (percentage), and load averages.
- `NervesHubLink.Extensions.Health.MetricSet.Memory` - Memory size (MB), used (MB), and percentage used.
- `NervesHubLink.Extensions.Health.MetricSet.Disk` - Disk size (KB), available (KB), and percentage used.

You can also create your own metric sets by implementing the `NervesHubLink.Extensions.Health.MetricSet`
behaviour.

If a library you are using provides a metric set, you can add it to the list of metrics, but please ensure
to include all the metric sets you want to use. If you want to include the full default set, you can use
`:default` or `:defaults` in your metric set list.

eg.

```
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

```
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

```
config :nerves_hub_link,
  health: [
    metric_sets: []
  ]
```

If you want to add custom metadata to the default health report, you can specify it with:

```
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

```
config :nerves_hub_link,
  health: [
    report: CatCounter.MyHealthReport
  ]
```

## Geolocation

It is intended to be easy to replace the default Geo Resolver with your own. Maybe you have a GPS module or can resolve a reasonably precise location via LTE. Just change config:

```
config :nerves_hub_link,
  geo: [
    resolver: CatCounter.MyResolver
  ]
```

Your module only needs to implement a single function, see `NervesHubLink.Extensions.Geo.Resolver` for details.


## Alarms

NervesHubLink will automatically report Erlang Alarms from `:alarm_handler` IF you have added a custom alarm handler. The default one is not very helpful and not intended for production use from what I gather. One well-used option is [`alarmist`](https://hex.pm/packages/alarmist).
