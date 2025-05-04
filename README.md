# NervesHubLink

[![Hex version](https://img.shields.io/hexpm/v/nerves_hub_link.svg "Hex version")](https://hex.pm/packages/nerves_hub_link)
[![API docs](https://img.shields.io/hexpm/v/nerves_hub_link.svg?label=hexdocs "API docs")](https://hexdocs.pm/nerves_hub_link/NervesHubLink.html)
[![CircleCI](https://dl.circleci.com/status-badge/img/gh/nerves-hub/nerves_hub_link/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/nerves-hub/nerves_hub_link/tree/main)
[![REUSE status](https://api.reuse.software/badge/github.com/nerves-hub/nerves_hub_link)](https://api.reuse.software/info/github.com/nerves-hub/nerves_hub_link)

`NervesHubLink` is the supported client library for connecting devices to [NervesHub](https://github.com/nerves-hub/nerves_hub_web).

This integration includes out-of-the-box support for:

- firmware updates
- debug tooling (iex console and support scripts)
- and device health telemetry

## Overview

[NervesHub](https://www.nerves-hub.org/) is an open-source IoT fleet management platform that is built specifically for Nerves-based devices.

Devices connect to the server by joining a long-lived websocket channel.

The NervesHub platform helps schedule firmware updates, providing firmware download information to the device which can be applied
immediately or [when convenient](guides/configuration.md#conditionally-applying-updates).

NervesHub does impose some requirements on devices and firmware that may require changes to your Nerves projects:

- Firmware images are cryptographically signed (both NervesHub and devices validate signatures)
- Devices are identified by a unique serial number

When using client certificate authentication, each device will also require its own SSL certificate for authentication with NervesHub.

These changes enable NervesHub to provide assurances that the firmware you intend to install on a set of devices make it to those devices unaltered.

> #### Info {: .info}
>
> This is the 2.x version of `NervesHubLink`.
>
> If you have been using [NervesHub](https://github.com/nerves-hub/nerves_hub_web) prior to around April, 2023 and have not updated to 2.0 or newer, please checkout the `maint-v1` branch.

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

_Important: Shared Secret authentication tailored for Hobby and R&D projects._

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

## Additional guides

- [Configuration](guides/configuration.md): Runtime and compile time configuration examples.
- [Extensions](guides/extensions.md): Setup and configure Health, Geo, and Logging extensions.
- [Debugging](guides/debugging.md): Tips to debug connection issues.

## Internal API Versions

`NervesHubLink.Configurator` includes two internal versions for NervesHub to determine what extensions are available on the device socket.

### `device_api_version`

- `2.2.0` - Report what extensions are enabled and their version
- `2.1.0` - Run scripts on a device separate from the console, sync firmware keys and archive keys
- `2.0.0` - Identify a device, archives
- `1.0.0` - Updating firmware, status updates, reboot device

### `console_version`

- `2.0.0` - Send and receive files from a device
- `1.0.0` - Remote IEx console
