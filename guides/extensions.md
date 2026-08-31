# Extensions: Health, Geo and more

Extensions are pieces of non-critical functionality going over the NervesHub WebSocket. They are separated out under the Extensions mechanism so that the client can happily ignore anything extension-related in service of keeping firmware updates healthy. That is always the top priority.

There are six extensions currently:

- [**Error Reports**](#error-reports) sends the device's exceptions and crashes to NervesHub, where they are grouped into issues you can resolve.
- [**Geo**](#geo) provides hooks to send a device's GeoIP information.
- [**Health**](#health) reports device metrics, alarms, metadata and similar.
- [**Local Shell**](#local-shell) gives NervesHub the ability to expose an interactive shell in the UI.
- [**Logging**](#logging) sends the device's log lines to NervesHub, where they are stored and searchable.
- [**Network Identity**](#network-identity) reports the device's identity on networks NervesHub doesn't run, such as iroh or NetBird.

Your NervesHub server controls enabling and disabling extensions to allow you to switch them off if they impact operations.

Which extensions a device offers is decided when it connects. The server names the extensions it has, and the versions of each, and the device offers back the ones it also implements. An extension the server does not name is not offered, so switching one off server-side stops the device doing the work as well as stops the reporting. A server that asks without naming anything is offered every extension this library implements, exactly as before. And nothing is offered until the server asks, so a server that never asks gets no extensions at all.

## Error Reports

The Error Reports extension sends the exceptions, exits and explicit error reports from your device to NervesHub, where they are grouped into issues you can resolve or mute. One direction only: nothing is ever sent back to the device.

It is off by default. To turn it on, name it in `extension_modules`:

```elixir
config :nerves_hub_link,
  extension_modules: [
    NervesHubLink.Extensions.ErrorReports,
    NervesHubLink.Extensions.Geo,
    NervesHubLink.Extensions.Health,
    NervesHubLink.Extensions.LocalShell,
    NervesHubLink.Extensions.NetworkIdentity
  ]
```

> #### This list replaces the defaults {: .warning}
>
> `extension_modules` replaces the default list rather than adding to it, so every extension you want has to be named, not just the one you are adding. `NervesHubLink.Extensions.LocalShell` is only in the default list when [`ExPTY`](https://hex.pm/packages/expty) is available, so leave it out of your list if you don't depend on it.

Enabling it here only makes the extension available. Like every extension, it sends nothing until NervesHub asks the device to attach it, which you control in your Product settings.

### What counts as an error

Anything the runtime attaches a `crash_reason` to. That covers a process dying from an exception, an exit or a throw, a GenServer terminating abnormally, and a failed `Task`. It is also what `Logger.error(message, crash_reason: {exception, stacktrace})` sets, so code that already reports that way is picked up without changing.

It is deliberately not every line logged at `:error`. Most of those are text, with no stacktrace to read and nothing to group two occurrences of the same bug by. It is also not only the reports OTP labels as crashes, which would miss anything reported by hand.

### Reporting an error you handled

Crashes report themselves. `NervesHubLink.report_error/3` is for the ones that never reach the runtime, where your code caught the error, dealt with it, and you still want to see it across the fleet:

```elixir
try do
  charge(order)
rescue
  error ->
    NervesHubLink.report_error(error, __STACKTRACE__,
      group: "payments",
      context: %{"order" => order.id}
    )

    :error
end
```

It returns `:ok` whether or not the extension is running, so a call to it is never the thing that takes your application down.

### How errors are grouped

NervesHub decides which occurrences are the same bug, from the kind of error, the reason with its per-occurrence detail stripped out, and the top few stack frames. Line numbers are ignored on purpose: a line moves whenever the file above it changes, and an issue that splits on every unrelated edit is worse than no grouping at all.

The `:group` option overrides that. Use it when your application knows something the stacktrace does not. Every failure in a payment integration arriving through one HTTP client function is one issue to the person on call, and six issues to a stacktrace.

### Attaching device state

Every report carries the device's uptime. Anything else is specific to your hardware and is not free to read, which matters because the moment of a crash is the worst time to go looking for it. So the rest is yours to supply:

```elixir
config :nerves_hub_link,
  error_reports: [context: {MyApp.Telemetry, :error_context, []}]
```

```elixir
defmodule MyApp.Telemetry do
  def error_context() do
    %{"reboot_count" => MyApp.reboot_count(), "site" => "depot-4"}
  end
end
```

The function is called once per batch on the extension's own process, never in the process that crashed, and one that raises costs the report its context and nothing else. Keys named `uptime_ms`, `free_memory_bytes` and `reboot_count` are given units in the NervesHub UI; everything else is shown as it arrives.

You do not need to send the firmware UUID. NervesHub fills that in from the device's connection.

### Buffering, and what is not sent

Reports collect from application start rather than from the attach, so a crash during boot, or while the device is offline, is still there to send once there is a connection. That is the crash you most want and the one that is hardest to catch.

A restart storm produces reports faster than they can be sent, so the buffer is bounded and drops the oldest past its limit. What it dropped is reported as an error of its own, ahead of the ones that survived, because a gap you can see beats a gap you cannot:

```elixir
config :nerves_hub_link,
  error_reports: [
    # How many reports the collector holds before dropping the oldest.
    max_reports: 100,
    # Never less than 60, whatever you put here.
    interval_seconds: 60
  ]
```

Sending is batched for the same reason logging is. NervesHub limits how often a device may send rather than how much it may say, so a message carrying twenty-five reports costs what one carrying a single report costs. A flush with more than that to send splits into several messages.

Reasons are cut at 2KB and messages at 8KB, and a stacktrace past 30 frames is trimmed, so one enormous crash cannot fill a message on its own.

## Geo

The Geo `NervesHubLink.Extensions.Geo.DefaultResolver` uses the https://whenwhere.nerves-project.org/ service to resolve the device's location using the publicly available IP address.

You can create your own resolver by implementing a module that implements the `NervesHubLink.Extensions.Geo.Resolver` behaviour. For example, if you have a GPS module, or your device can resolve a reasonably precise location via LTE, you could implement your own resolver called `MyApp.GPSGeoResolver` and update the config to:

```
config :nerves_hub_link,
  geo: [
    resolver: MyApp.GPSGeoResolver
  ]
```

Please see `NervesHubLink.Extensions.Geo.Resolver` for more information.

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

The `Health.DefaultReport` also sends the current system alarms to the connected NervesHub platform.

A built in default is to filter out the `:disk_almost_full` alarm for the `/` mount. This alarm is generated by Erlang upon startup, based on how the read-only root filesystem is sized to fit only whats included in the firmware.

You can customize the mounts ignored with:

```
config :nerves_hub_link,
  health: [
    alarms: [
      ignore_disk_full_mounts: [
        "/a_different_mount"
      ]
    ]
  ]
```

Specifying a list of mounts to ignore will override the default `/`, so make sure to include that in the list if you want to continue ignoring `/` while also adding other mounts.

### Alarms

The [default health report](`NervesHubLink.Extensions.Health.DefaultReport`) uses `:alarm_handler`, but we
recommend the [`alarmist`](https://hex.pm/packages/alarmist) library for improved alarms handling.

## Local Shell

Provides an interactive local shell for NervesHub to connect to. This is useful for debugging and troubleshooting issues with the device.

This extension is enabled by default, but must also be enabled in your Device and Product settings on your NervesHub platform.

To use this extension, you need to include the [`ExPTY`](https://hex.pm/packages/expty) library in your project's dependencies.

## Logging

The Logging extension is responsible for sending logs to the NervesHub platform.

It is in early release and is off by default. To turn it on, name it in `extension_modules`:

```elixir
config :nerves_hub_link,
  extension_modules: [
    NervesHubLink.Extensions.Geo,
    NervesHubLink.Extensions.Health,
    NervesHubLink.Extensions.LocalShell,
    NervesHubLink.Extensions.NetworkIdentity,
    NervesHubLink.Extensions.Logging
  ]
```

> #### This list replaces the defaults {: .warning}
>
> `extension_modules` replaces the default list rather than adding to it, so every extension you want has to be named, not just the one you are adding. `NervesHubLink.Extensions.LocalShell` is only in the default list when [`ExPTY`](https://hex.pm/packages/expty) is available, so leave it out of your list if you don't depend on it.

Enabling it here only makes the extension available. Like every extension, it sends nothing until NervesHub asks the device to attach it, which you control in your Device and Product settings.

### Choosing what gets sent

Every log line is a message over the socket, so only `:info` and above are sent by default. Devices on metered connections will want to raise that:

```elixir
config :nerves_hub_link,
  logging: [level: :warning]
```

Any [Logger level](https://hexdocs.pm/logger/Logger.html#t:level/0) is accepted, as is `:all` to send everything the `Logger` level allows through.

Each line also carries the metadata `Logger` attached to it. That is everything by default, which includes the pid and group leader of the process that logged, and on a crash the whole reason and stacktrace. To send less, name the keys you want:

```elixir
config :nerves_hub_link,
  logging: [metadata: [:mfa, :file, :line]]
```

The timestamp is always sent, whatever you set here. NervesHub needs it to store the line at all.

### Sending a minute at a time

There are two versions of this extension, and they are the same feature: 0.0.1 sends a message per log line, 0.1.0 collects lines and sends a minute of them at a time.

Naming `NervesHubLink.Extensions.Logging` gets you both. There is nothing extra to configure: the device offers whichever version your NervesHub has, and prefers 0.1.0 where it is available.

**Why it matters.** NervesHub limits how often a device may send rather than how much it may say: a few messages a second, and anything past that is dropped without telling the device. At a message per line that is a limit on *lines*, and boot is when a device logs fastest, so the lines most worth having are the ones most likely to go. At a minute per message the same budget carries a minute of logs.

0.1.0 also collects from application start rather than from the attach, so the boot is still there to send, and holds the lines in a bounded buffer, reporting anything it had to drop:

```elixir
config :nerves_hub_link,
  logging: [
    level: :info,
    # How many lines the collector holds before dropping the oldest.
    max_lines: 1000,
    # Never less than 60, whatever you put here.
    interval_seconds: 60
  ]
```

### What is not sent

On 0.0.1 the handler is installed when the extension is attached and removed when it is detached, so lines written before that are not sent. 0.1.0 collects from application start instead, and has the boot.

0.0.1 sends only lines of text. Reports, which is how OTP logs a crash, a supervisor starting a child, or an alarm, are skipped by it. 0.1.0 sends those too, on one line and bounded in length, since they are most of what you want when a device misbehaves.

Any single line longer than 8KB is cut short and marked, so one line cannot fill a message on its own.

## Network Identity

Devices increasingly reach the outside world over something other than their NervesHub socket — an iroh endpoint, a NetBird or Tailscale peer, a plain WireGuard interface. Each of those networks names the device by a long-lived public key, and that key is what you need in order to reach it by any route other than NervesHub.

This extension reports those identities so they show up on the device page in NervesHub, where an operator can copy one without opening a console.

There is no default provider, and there can't be one: NervesHubLink has no way to know that your device is also an iroh endpoint. The library that owns the identity does, so you point the extension at a module that can answer.

```elixir
config :nerves_hub_link,
  network_identity: [
    providers: [MyApp.IrohIdentity],
    interval_minutes: 5
  ]
```

One provider reports one service. A device on both iroh and NetBird configures two.

### When identities are sent

NervesHub asks for all of them once, when the extension attaches. After that the device asks its own providers every `interval_minutes` and sends only what changed.

The key itself doesn't move — that's what makes it an identity. What changes is everything a provider puts beside it: a device that switches relay keeps its endpoint id and changes the address anyone would reach it on. A stale address is worse than no address when it's the only route to the device.

Nothing goes over the wire when nothing has changed, so the interval costs one local call per provider and no traffic. Set `interval_minutes: 0` to turn the poll off and send only on connect.

A provider that already knows the moment its identity changed doesn't have to wait for the poll:

```elixir
NervesHubLink.Extensions.NetworkIdentity.send_identity(MyApp.IrohIdentity)
```

`send_identities/0` sends every provider's, changed or not.

### Writing a provider

Implement `NervesHubLink.Extensions.NetworkIdentity.Provider`, which is a single `identity/0` callback. For a device running [`iroh_console`](https://hex.pm/packages/iroh_console):

```elixir
defmodule MyApp.IrohIdentity do
  @behaviour NervesHubLink.Extensions.NetworkIdentity.Provider

  @impl true
  def identity() do
    # One addr/1 call, so the id and the ticket describe the same moment.
    # IrohConsole.Server.ticket/1 reads the address again, so asking for both
    # can pair an id with a ticket built after a relay change.
    with {:ok, addr} <- IrohConsole.Server.addr(),
         {:ok, ticket} <- IrohBeam.EndpointTicket.new(addr) do
      {:ok,
       %{
         service: "iroh",
         identifier: to_string(addr.id),
         details: %{"ticket" => to_string(ticket)}
       }}
    else
      # The console isn't up yet, or isn't running on this unit at all
      {:error, :not_running} -> :unavailable
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Note which value goes where. The **endpoint id** is the identifier: it is the key the device proves it holds, and it doesn't change. The **ticket** goes in `details`, because it bundles the id together with the relay and direct addresses the device is currently reachable on — which do change. They are not interchangeable, and only the ticket can be dialled.

### More than one endpoint of the same service

A device can run two iroh endpoints — a remote console, plus whatever the application itself uses iroh for — each with its own key. Both are `iroh`, so name the `instance` to tell them apart:

```elixir
{:ok, %{service: "iroh", instance: "app_sync", identifier: key, details: %{}}}
```

Omit it and NervesHub treats the identity as that service's only endpoint, which is what you want for a singleton like Tailscale. `iroh_console` reports itself as `iroh_console`, so an endpoint of your own only needs a name that isn't that.

The same applies to WireGuard, where `wg0` and `wg1` are two identities of one protocol.

**Pick something stable.** NervesHub keys the identity on the instance, so one that changes between reports creates a second record instead of updating the first. The name of the library or feature owning the endpoint works well; anything derived from the key does not — the key is exactly the thing that might rotate, and surviving a rotation is the point.

The same shape works for anything else. A NetBird provider is really just parsing that agent's status:

```elixir
defmodule MyApp.NetBirdIdentity do
  @behaviour NervesHubLink.Extensions.NetworkIdentity.Provider

  @impl true
  def identity() do
    case System.cmd("netbird", ["status", "--json"]) do
      {output, 0} ->
        status = Jason.decode!(output)

        {:ok,
         %{
           service: "netbird",
           identifier: status["publicKey"],
           details: %{"ip" => status["netbirdIp"], "fqdn" => status["fqdn"]}
         }}

      {_output, _code} ->
        :unavailable
    end
  end
end
```

### `:unavailable` versus `{:error, reason}`

Both skip the provider, and both are fine — the difference is only how loudly it is logged.

Return `:unavailable` when there is simply nothing to report: the endpoint hasn't started, or this particular unit isn't on that network. It's logged at debug. Return `{:error, reason}` when something is actually wrong, and it's logged as a warning.

The distinction matters because devices reconnect often. If a unit that legitimately has no iroh identity produced a warning every time it connected, the warnings would stop meaning anything.

A provider that raises is caught, logged and skipped — one broken provider never costs the others their identities, and never disturbs the socket.

### Which services NervesHub understands

Currently `iroh`, `netbird`, `tailscale` and `wireguard`. Anything else is discarded by the server, deliberately and quietly, so that reporting something unknown never costs a device its other identities. Adding a service is a change to NervesHub itself.

Keep `details` small — NervesHub rejects a payload over 4KB once encoded — and never put a secret in it. This is an identity record, and it's visible to anyone who can view the device.

### Checking what your providers return

To see what they currently answer without sending anything, which is the quickest way to work out why a device isn't showing what you expect:

```elixir
NervesHubLink.Extensions.NetworkIdentity.identities()
```

Like every extension, this must also be enabled in your Product and Device settings on your NervesHub platform.
