# NervesHubLink

[![CircleCI](https://circleci.com/gh/nerves-hub/nerves_hub_link/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-hub/nerves_hub_link/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_hub_link.svg "Hex version")](https://hex.pm/packages/nerves_hub_link)

This is the official client for devices that want to receive firmware updates from NervesHub.

## Overview

NervesHub is an open-source firmware update server that works well with
Nerves-based devices. A managed version is available at
[nerves-hub.org](https://nerves-hub.org) and it's possible to host your own.

NervesHub provides many of the features that you'd expect in a firmware update
server. Fundamentally, devices connect to the server by joining a long-lived Phoenix
channel (for HTTP polling, see [nerves_hub_link_http](https://github.com/nerves-hub/nerves_hub_link_http)).
If a firmware update is available, NervesHub will provide a URL to the device and the
device can update immediately or [when convenient](https://github.com/nerves-hub/nerves_hub_link#conditionally-applying-updates).

NervesHub does impose some requirements on devices and firmware that may require
changes to your Nerves projects:

* Firmware images are cryptographically signed (both NervesHub and devices
  validate signatures)
* Devices are identified by a unique serial number
* Each device has its own SSL certificate for authentication with NervesHub

These changes enable NervesHub to provide assurances that the firmware bits
you intend to install on a set of devices make it to those devices unaltered.

## Getting started

The following sections will walk you through updating your Nerves project to
work with the [nerves-hub.org](https://nerves-hub.org) NervesHub server. Using
your own NervesHub server will require setting URLs to point elsewhere and is
not covered below to simplify first usage.

Many of the steps below may feel manual, but they can and are automated by
NervesHub users to set up automatic firmware updates from CI and to manufacture
large numbers of devices.

### Creating an account on nerves-hub.org

The [nerves-hub.org](https://nerves-hub.org) NervesHub server is currently in
limited beta so it does not allow new users to sign up. However, you found these
docs and if you can use `mix` and endure some API changes, you can join us.

In addition to the web site, NervesHub provides a command line interface (CLI).
Some features are only available via the CLI. To enable the CLI in your project,
add [nerves_hub_cli](https://hex.pm/packages/nerves_hub_cli) to your dependency
list:

```elixir
  defp deps do
    [
      {:nerves, "~> 1.7", runtime: false},
      {:nerves_hub_cli, "~> 0.10", runtime: false}
      ...
    ] ++ deps(@target)
  end
```

Run `mix deps.get` to download the `nerves_hub_cli` dependency.

Presumably you do not have an account yet. Create one by running:

```bash
mix nerves_hub.user register
```

If you already have an account, make sure that you have authenticated by running:

```bash
mix nerves_hub.user auth
```

### Adding NervesHubLink to your project

The first step is to add `nerves_hub_link` to your target dependencies in your
project's `mix.exs`. Since NervesHub uses SSL certificates, the time must be set
on the device or certificate validity checks will fail. If you're not already
setting the time, add [`nerves_time`](https://hex.pm/packages/nerves_time) to
your dependencies. For example:

```elixir
  defp deps(target) do
    [
      {:nerves_runtime, "~> 0.11"},
      {:nerves_hub_link, "~> 0.11"},
      {:nerves_time, "~> 0.4"},
      ...
    ] ++ system(target)
  end
```

Next, update your `config.exs` so that the `nerves_hub_link` library can help
provision devices. Do this by adding `provisioning: :nerves_hub_link` to the
`:nerves, :firmware` option like this:

```elixir
config :nerves, :firmware,
  provisioning: :nerves_hub_link
```

The library won't connect to [nerves-hub.org](https://nerves-hub.org) unless
requested and SSL options must be configured.

If using [NervesKey](https://github.com/nerves-hub/nerves_key), you can tell
`NervesHubLink` to read those certificates and key from the chip and assign
the SSL options for you by enabling add it as a dependency:

```elixir
def deps() do
  [
    {:nerves_key, "~> 0.5"}
  ]
end
```

NervesKey will default to using I2C bus 1 and the `:primary` certificate pair
(`:primary` is one-time configurable and `:aux` may be updated).  You can
customize these options to use a different bus and certificate pair:

```elixir
config :nerves_hub_link, :nerves_key,
  certificate_pair: :aux,
  i2c_bus: 0
```

If you aren't using NervesKey, you can also provide your own options
to use for the NervesHub socket connection via the `:socket` and `:ssl` keys,
which are forwarded on to `phoenix_client` when creating the socket connection (see
[`PhoenixClient.Socket`
module](https://github.com/mobileoverlord/phoenix_client/blob/main/lib/phoenix_client/socket.ex#L57-L91)
for support options.

Any [valid Erlang ssl socket
option](http://erlang.org/doc/man/ssl.html#TLS/DTLS%20OPTION%20DESCRIPTIONS%20-%20COMMON%20for%20SERVER%20and%20CLIENT)
can go in the `:ssl` key.

```elixir
config :nerves_hub_link,
  socket: [
    json_library: Jason,
    heartbeat_interval: 45_000
  ],
  ssl: [
    cert: "some_cert_der",
    keyfile: "path/to/keyfile"
  ]
```

### Runtime configuration

Some cases require that connection configuration happens at runtime like
selectively choosing which cert/key to use based on device, or reading a file
stored on device which isn't available during compilation.

Whatever the reason, `NervesHubLink` also supports runtime configuration via the
`NervesHubLink.Configurator` behavior. This is called during application startup
to build the configuration that is to be used for the connection. When
implementing the behavior, you'll receive the initial default config read in
from the application environment and you can modify it however you need.

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

### Creating a NervesHub product

A NervesHub product groups devices that run the same kind of firmware. All
devices and firmware images have a product. NervesHub provides finer grain
mechanisms for grouping devices, but a product is needed to get started.

By default, NervesHub uses the `:app` name in your `mix.exs` for the product
name. If you would like it to use a different name, add a `:name` field to your
`Mix.Project.config()`. For example, NervesHub would use "My Example" instead of
"example" for the following project:

```elixir
  def project do
    [
      app: :example,
      name: "My Example"
    ]
  end
```

For the remainder of this document, though, we will not use the `:name` field
and simply use the product name `example`.

Create a new product on NervesHub by running:

```bash
mix nerves_hub.product create
```

### Creating NervesHub firmware signing keys

NervesHub requires cryptographic signatures on all managed firmware. Devices
receiving firmware from NervesHub validate signatures. Since firmware is signed
before uploading to NervesHub, NervesHub or any service NervesHub uses cannot
modify it.

Firmware authentication uses [Ed25519 digital
signatures](https://en.wikipedia.org/wiki/EdDSA#Ed25519). You need to create at
least one public/private key pair and copy the public key part to NervesHub and
to devices. NervesHub tooling helps with both. A typical setup has multiple
signing keys to support key rotation and "development" keys that are not as
protected.

Start by creating a `devkey` firmware signing key pair:

```bash
mix nerves_hub.key create devkey
```

On success, you'll see the public key. You can confirm using the NervesHub web
interface that the public key exists. Private keys are never sent to the
NervesHub server. NervesHub requires valid signatures from known keys on all
firmware it distributes.

The next step is to make sure that the public key is embedded into the firmware
image. This is important. The device uses this key to verify the firmware it
receives from a NervesHub server before applying the update. This protects the
device against anyone tampering with the firmware image between when it was
signed by you and when it is installed.

All firmware signing public keys need to be added to your `config.exs`. Keys
that are stored locally (like the one we just created) can be referred to by
their atom name:

```elixir
config :nerves_hub_link,
  fwup_public_keys: [:devkey]
```

If you have keys that cannot be stored locally, you will have to copy/paste
their public key:

```elixir
config :nerves_hub_link,
  fwup_public_keys: [
    # devkey
    "bM/O9+ykZhCWx8uZVgx0sU3f0JJX7mqnAVU9VGeuHr4="
  ]
```

The `nerves_hub_link` dependency converts key names to public keys at compile time.
If you haven't compiled your project yet, run `mix firmware` now. If you have
compiled it, `mix` won't know to recompile `nerves_hub_link` due to the configuration
change. Force it to recompile by running:

```bash
mix deps.compile nerves_hub_link --force
mix firmware
```

While not shown here, you can export keys for safe storage. Additionally, key
creation and firmware signing can be done outside of the `mix` tooling. The only
part that is required is that the firmware signing public keys be added to your
`config.exs` and to the NervesHub server.

### Publishing firmware

Uploading firmware to NervesHub is called publishing. To publish firmware start
by calling:

```bash
mix firmware
```

Firmware can only be published if has been signed. You can sign the firmware by
running.

```bash
mix nerves_hub.firmware sign --key devkey
```

Firmware can also be signed while publishing:

```bash
mix nerves_hub.firmware publish --key devkey
```

### Initializing devices

In this example we will create a device with a hardware identifier `1234`.  The
device will also be tagged with `qa` so we can target it in our deployment
group. We will select `y` when asked if we would like to generate device
certificates. Device certificates are required for a device to establish a
connection with the NervesHub server. However, if you are using [NervesKey](https://github.com/nerves-hub/nerves_key),
you can select `n` to skip generating device certificates.

```bash
$ mix nerves_hub.device create

NervesHub organization: nerveshub
identifier: 1234
description: test-1234
tags: qa
Local user password:
Device 1234 created
Would you like to generate certificates? [Yn] y
Creating certificate for 1234
Finished
```

It is important to note that device certificate private keys are generated and
stay on your host computer. A certificate signing request is sent to the server,
and a signed public key is passed back. Generated certificates will be placed in
a folder titled `nerves-hub` in the current working directory. You can specify a
different location by passing `--path /path/to/certs` to NervesHubCLI mix
commands.

NervesHub certificates and hardware identifiers are persisted to the firmware
when the firmware is burned to the SD card. To make this process easier, you can
call `nerves_hub.device burn IDENTIFIER`. In this example, we are going to burn
the firmware and certificates for device `1234` that we created.

```bash
mix nerves_hub.device burn 1234
```

Your device will now connect to NervesHub when it boots and establishes an
network connection.

### Creating deployments

Deployments associate firmware images to devices. NervesHub won't send firmware
to a device until you create a deployment. First find the UUID of the firmware.
You can list the firmware on NervesHub by calling:

```bash
mix nerves_hub.firmware list

Firmwares:
------------
  product:      example
  version:      0.3.0
  platform:     rpi3
  architecture: arm
  uuid:         1cbecdbb-aa7d-5aee-4ba2-864d518417df
```

In this example we will create a new deployment for our test group using firmware
`1cbecdbb-aa7d-5aee-4ba2-864d518417df`.

```bash
mix nerves_hub.deployment create

NervesHub organization: nerveshub
Deployment name: qa_deployment
firmware uuid: 1cbecdbb-aa7d-5aee-4ba2-864d518417df
version condition:
tags: qa
Local user password:
Deployment test created
```

Here we create a new deployment called `qa_deployment`. In the conditions of this
deployment we left the `version condition` unspecified and the `tags` set to
only `qa`.  This means that in order for a device to qualify for an update, it
needs to have at least the tags `[qa]` and the device can be coming from any
version.

At this point we can try to update the connected device.

Start by bumping the application version number from `0.1.0` to `0.1.1`. Then,
create new firmware:

```bash
mix firmware
```

We can publish, sign, and deploy firmware in a single command now.

```bash
mix nerves_hub.firmware publish --key devkey --deploy qa_deployment
```

### Conditionally applying updates

It's not always appropriate to apply a firmware update immediately.
Custom logic can be added to the device by implementing the `NervesHubLink.Client` behaviour and telling the NervesHubLink OTP application about it.

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

It's possible to remotely log into your device via the NervesHub web interface. This
feature is disabled by default. To enable, add the following to your `config.exs`:

```elixir
config :nerves_hub_link, remote_iex: true
```

The remote IEx process is started on the first data request from NervesHub and is
terminated after 5 minutes of inactivity. You can adjust this by setting
`:remote_iex_timeout` value in seconds in your `config.exs`:

```elixir
config :nerves_hub_link, remote_iex_timeout: 900 # 15 minutes
```

You may also need additional permissions on NervesHub to see the device and to use the
remote IEx feature.

## CA Certificates

If you are connecting to the publicly available https://nerves-hub.org instance, then
then you don't need to do anything here as they are handled by default with
[`NervesHubCAStore`](https://github.com/nerves-hub/nerves_hub_ca_store).
If you are connecting to your own instance with custom CA certificates, use the
`:ca_store` option to specific a module with a `ca_certs/0` function that returns
a list of DER encoded certificates:

```elixir
config :nerves_hub_link, ca_store: MyModule
```

Or if you have the certificates in DER format, you can also explicitly set them in the :ssl option:

```elixir
my_der_list = [<<213, 34, 234, 53, 83, 8, 2, ...>>]
config :nerves_hub_link, ssl: [cacerts: my_der_list]
```

## Debugging errors

### TLS client errors

If you see the following in your logs:

```text
14:26:06.926 [info]  ['TLS', 32, 'client', 58, 32, 73, 110, 32, 115, 116, 97, 116, 101, 32, 'cipher', 32, 'received SERVER ALERT: Fatal - Unknown CA', 10]
```

This probably indicates that the signing certificate hasn't been uploaded to
nerves-hub.org so the device can't be authenticated. Double check that you ran:

```sh
mix nerves_hub.ca_certificate register my-signer.cert
```

Another possibility is that the device wasn't provisioned with the certificate
that's on nerves-hub.org.

See also [NervesHubWeb: Potential SSL Issues](https://github.com/nerves-hub/nerves_hub_web#potential-ssl-issues)
