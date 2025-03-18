# Extensions: Health and Geo

Extensions are pieces of non-critical functionality going over the NervesHub WebSocket. They are separated out under the Extensions mechanism so that the client can happily ignore anything extension-related in service of keeping firmware updates healthy. That is always the top priority.

There are two extensions currently:

- **Health** reports device metrics, alarms, metadata and similar.
- **Geo** provides GeoIP information and allows slotting in a better source.

Your NervesHub server controls enabling and disabling extensions to allow you to switch them off if they impact operations.

## Health

You can add your own metrics, metadata and alarms:

In your config.exs for the device:

```
config :nerves_hub_link,
  health: [
    # metrics are added with a key and MFA
    # the function should return a number (int or float is fine)
    metrics: %{
      "cats_passed" => {CatCounter, :total, []}
    },

    # metadata is identical but should return a string
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
