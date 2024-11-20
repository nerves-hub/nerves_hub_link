# NervesHubLink

[![CircleCI](https://circleci.com/gh/nerves-hub/nerves_hub_link/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-hub/nerves_hub_link/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_hub_link.svg "Hex version")](https://hex.pm/packages/nerves_hub_link)

The Device-side client library for NervesHub.

This is the 2.x version NervesHubLink. If you have been using NervesHub prior to around April, 2023 and have not updated to 2.0 or newer see the `maint-v1` branch.

---

## Overview

[NervesHub](https://www.nerves-hub.org/) is an open-source IoT fleet management server that is built specifically for Nerves-based devices.

Devices connect to the server by joining a long-lived Phoenix channel (for HTTP polling, see [nerves_hub_link_http](https://github.com/nerves-hub/nerves_hub_link_http)). If a firmware update is available, NervesHub will provide a URL to the device and the device can update immediately or [when convenient](https://github.com/nerves-hub/nerves_hub_link#conditionally-applying-updates).

NervesHub does impose some requirements on devices and firmware that may require changes to your Nerves projects:

- Firmware images are cryptographically signed (both NervesHub and devices validate signatures)
- Devices are identified by a unique serial number

When using client certificate authentication, each device will also require its own SSL certificate for authentication with NervesHub.

These changes enable NervesHub to provide assurances that the firmware you intend to install on a set of devices make it to those devices unaltered.

## Getting started

The following sections will walk you through updating your Nerves project to work with a NervesHub server.

Many of the steps below can be automated by NervesHub users to set up automatic firmware updates from CI and to manufacture large numbers of devices.

### Adding NervesHubLink to your project

The first step is to add `nerves_hub_link` to your target dependencies in your
project's `mix.exs`. For example:

```elixir
  defp deps(target) do
    [
      {:nerves_runtime, "~> 0.13"},
      {:nerves_hub_link, "~> 2.2"},
      ...
    ] ++ system(target)
  end
```

### Connecting your device to NervesHub

#### Shared secret device authentication

_Important: Shared Secret authentication is a new feature under active development._

Shared Secrets use [HMAC](https://en.wikipedia.org/wiki/HMAC) cryptography to generate an authentication token used during websocket connection.

This has been built with simple device registration in mind, an ideal fit for hobby projects or projects under early R&D.

You can generate a key and secret in your NervesHub Product settings which you then include in your `NervesHubLink` settings.

A full example config:

```elixir
config :nerves_hub_link,
  host: "your.nerveshub.host",
  shared_secret: [
    product_key: "<product_key>",
    product_secret: "<product_secret>",
  ]
```

#### NervesKey (with cert based auth)

_Important: This is recommended for production device fleets._

If your project is using [NervesKey](https://github.com/nerves-hub/nerves_key), you can tell `NervesHubLink` to read those certificates and key from the chip and assign the SSL options for you by adding it as a dependency:

```elixir
def deps() do
  [
    {:nerves_key, "~> 1.2"}
  ]
end
```

This allows your config to be simplified to:

```elixir
config :nerves_hub_link,
  host: "your.nerveshub.host"
```

NervesKey will default to using I2C bus 1 and the `:primary` certificate pair (`:primary` is one-time configurable and `:aux` may be updated). You can customize these options to use a different bus and certificate pair:

```elixir
config :nerves_hub_link, :nerves_key,
  certificate_pair: :aux,
  i2c_bus: 0
```

#### Certificate device authentication

If you would like to use certificate device authentication, but you are not using `NervesKey`, you can tell `NervesHubLink` to read the certificate and key from the file system by using:

```elixir
config :nerves_hub_link,
  host: "your.nerveshub.host",
  configurator: NervesHubLink.Configurator.LocalCertKey
```

By default the configurator will use a certificate found at `/data/nerves_hub/cert.pem` and a key found at `/data/nerves_hub/key.pem`. If these are stored somewhere differently then you can specify `certfile` and `keyfile` in the `ssl` config, e.g.:

```elixir
config :nerves_hub_link,
  host: "your.nerveshub.host",
  configurator: NervesHubLink.Configurator.LocalCertKey,
  ssl: [
    certfile: "/path/to/certfile.pem",
    keyfile: "/path/to/keyfile.key"
  ]
```

For more information on how to generate device certificates, please read the ["Initializing devices"](#https://github.com/nerves-hub/nerves_hub_cli#initializing-devices) section in the `NervesHubCLI` readme.

#### Additional notes

Any [valid Erlang ssl socket option](http://erlang.org/doc/man/ssl.html#TLS/DTLS%20OPTION%20DESCRIPTIONS%20-%20COMMON%20for%20SERVER%20and%20CLIENT) can go in the `:ssl` key. These options are passed to [Mint](https://hex.pm/packages/mint) by [Slipstream](https://hex.pm/packages/slipstream), which `NervesHubLink` uses for websocket connections.

### Runtime configuration

`NervesHubLink` also supports runtime configuration via the `NervesHubLink.Configurator` behavior. This is called during application startup to build the configuration that is to be used for the connection. When implementing the behavior, you'll receive the initial default config read in from the application environment and you can modify it however you need.

This is useful for cases like:

- selectively choosing which cert/key to use
- reading a certificate file stored on the device which isn't available during compilation

For example:

```elixir
defmodule MyApp.Configurator do
  @behaviour NervesHubLink.Configurator

  @impl NervesHubLink.Configurator
  def build(config) do
    ssl = [certfile: "/root/ssl/cert.pem", keyfile: "/root/ssl/key.pem"]
    %{config | ssl: ssl}
  end
end
```

Then you specify which configurator `NervesHubLink` should use in `config.exs`:

```elixir
config :nerves_hub_link, configurator: MyApp.Configurator
```

## Advanced extensions

### Conditionally applying updates

It's not always appropriate to apply a firmware update immediately. Custom logic can be added to the device by implementing the `NervesHubLink.Client` behaviour and telling the NervesHubLink OTP application about it.

Here's an example implementation:

```elixir
defmodule MyApp.NervesHubLinkClient do
   @behaviour NervesHubLink.Client

   # May return:
   #  * `:apply` - apply the action immediately
   #  * `:ignore` - don't apply the action, don't ask again.
   #  * `{:reschedule, timeout_in_milliseconds}` - call this function again later.

   @impl NervesHubLink.Client
   def update_available(data) do
    if SomeInternalAPI.is_now_a_good_time_to_update?(data) do
      :apply
    else
      {:reschedule, 60_000}
    end
   end
end
```

To have NervesHubLink invoke it, update your `config.exs` as follows:

```elixir
config :nerves_hub_link, client: MyApp.NervesHubLinkClient
```

### Reporting update progress

See the previous section for implementing a `client` behaviour.

```elixir
defmodule MyApp.NervesHubLinkClient do
  @behaviour NervesHubLink.Client
  #  argument can be:
  #   {:ok, non_neg_integer(), String.t()}
  #   {:warning, non_neg_integer(), String.t()}
  #   {:error, non_neg_integer(), String.t()}
  #   {:progress, 0..100}
  def handle_fwup_message({:ok, _, _}) do
    Logger.error("Firmware update complete")
    :ok
  end

  def handle_fwup_message({:warning, code, message}) do
    Logger.error("Warning while applying firmware update (#{code)}): #{message}")
    :ok
  end

  def handle_fwup_message({:error, _, message}) do
    Logger.error("Error while applying firmware update #(#{code}): {message}")
    :ok
  end

  def handle_fwup_message({:progress, progress}) when rem(progress, 10) do
    Logger.info("Update progress: #{progress}%")
    :ok
  end

  def handle_fwup_message({:progress, _}) do
    :ok
  end
end
```

### Enabling remote IEx access

It's possible to remotely log into your device via the NervesHub web interface. This feature is disabled by default. To enable, add the following to your `config.exs`:

```elixir
config :nerves_hub_link, remote_iex: true
```

The remote IEx process is started on the first data request from NervesHub and is terminated after 5 minutes of inactivity. You can adjust this by setting `:remote_iex_timeout` value in seconds in your `config.exs`:

```elixir
config :nerves_hub_link, remote_iex_timeout: 900 # 15 minutes
```

You may also need additional permissions on NervesHub to see the device and to use the remote IEx feature.

### Alarms

This application can set and clear the following alarms:

- `NervesHubLink.Disconnected`
  - set: An issue is preventing a connection to NervesHub or one just hasn't been made yet
  - clear: Currently connected to NervesHub
- `NervesHubLink.UpdateInProgress`
  - set: A new firmware update is being downloaded or applied
  - clear: No updates are happening

### CA Certificates

The CA certificates installed on the device are used by default.

If you include the [CAStore](https://hex.pm/packages/castore) in your project, then that will be selected and used.

Otherwise you can configure `nerves_hub_link` to use custom CA certificates, which is useful if you are running your own NervesHub instance with self signed SSL certificates. Use the `:ca_store` option to specify a module with a `ca_certs/0` function that returns a list of DER encoded certificates:

```elixir
config :nerves_hub_link, ca_store: MyModule
```

Or if you have the certificates in DER format, you can also explicitly set them in the :ssl option:

```elixir
my_der_list = [<<213, 34, 234, 53, 83, 8, 2, ...>>]
config :nerves_hub_link, ssl: [cacerts: my_der_list]
```

### Verifying network availability

`NervesHubLink` will attempt to verify that the network is available before initiating the first connection attempt. This is done by checking if the `NervesHub` host address (`config.host`) can be resolved. If the network isn't available then the check will be run again in 2 seconds.

You can disable this behaviour with the following config:

```elixir
config :nerves_hub_link, connect_wait_for_network: false
```

### Disable `NervesHubLink` during testing

To disable `NervesHubLink` connecting to `NervesHub` when testing, you can add:

```elixir
config :nerves_hub_link, connect: false
```

to your `config/test.exs`

## Extensions: Health & Geo

Extensions are pieces of non-critical functionality going over the NervesHub WebSocket. They are separated out under the Extensions mechanism so that the client can happily ignore anything extension-related in service of keeping firmware updates healthy. That is always the top priority.

There are two extensions currently:

- **Health** reports device metrics, alarms, metadata and similar.
- **Geo** provides GeoIP information and allows slotting in a better source.

Your NervesHub server controls enabling and disabling extensions to allow you to switch them off if they impact operations.

### Configure Health

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
    metrics: %{
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

## Configure Geo

It is intended to be easy to replace the default Geo Resolver with your own. Maybe you have a GPS module or can resolve a reasonably precise location via LTE. Just change config:

```
config :nerves_hub_link,
  geo: [
    resolver: CatCounter.MyResolver
  ]
```

Your module only needs to implement a single function, see `NervesHubLink.Extensions.Geo.Resolver` for details.


## Configure Alarms

NervesHubLink will automatically report Erlang Alarms from `:alarm_handler` IF you have added a custom alarm handler. The default one is not very helpful and not intended for production use from what I gather. One well-used option is [`alarmist`](https://hex.pm/packages/alarmist).

## Debugging errors

### TLS client errors

If you see the following in your logs:

```text
14:26:06.926 [info]  ['TLS', 32, 'client', 58, 32, 73, 110, 32, 115, 116, 97, 116, 101, 32, 'cipher', 32, 'received SERVER ALERT: Fatal - Unknown CA', 10]
```

This probably indicates that the signing certificate hasn't been uploaded to NervesHub so the device can't be authenticated. Double check that you ran:

```sh
mix nerves_hub.ca_certificate register my-signer.cert
```

Another possibility is that the device wasn't provisioned with the certificate
that's on NervesHub.

See also [NervesHubWeb: Potential SSL Issues](https://github.com/nerves-hub/nerves_hub_web#potential-ssl-issues)

## Internal API Versions

`NervesHubLink.Configurator` includes two internal versions for NervesHub to determine what extensions are available on the device socket.

### `device_api_version`

- `1.0.0` - Updating firmware, status updates, reboot device
- `2.0.0` - Identify a device, archives
- `2.1.0` - Run scripts on a device separate from the console, sync firmware keys and archive keys

### `console_version`

- `1.0.0` - Remote IEx console
- `2.0.0` - Send and receive files from a device
