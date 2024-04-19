# NervesHubLink

[![CircleCI](https://circleci.com/gh/nerves-hub/nerves_hub_link/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-hub/nerves_hub_link/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_hub_link.svg "Hex version")](https://hex.pm/packages/nerves_hub_link)

**Important**

This is the 2.0 development branch of NervesHubLink. If you have been using NervesHub prior to around April, 2023 and are not following 2.0 development, see the `maint-v1` branch. The `maint-v1` branch is being used in production. 2.0 development is in progress, and we don't have guides or good documentation yet. If you use the 2.0 development branch, we don't expect breaking changes, but please bear with us as we complete the 2.0 release.

---

## Overview

[NervesHub](https://www.nerves-hub.org/) is an open-source IoT fleet management server that is built specifically for Nerves-based devices.

Devices connect to the server by joining a long-lived Phoenix channel (for HTTP polling, see [nerves_hub_link_http](https://github.com/nerves-hub/nerves_hub_link_http)). If a firmware update is available, NervesHub will provide a URL to the device and the device can update immediately or [when convenient](https://github.com/nerves-hub/nerves_hub_link#conditionally-applying-updates).

NervesHub does impose some requirements on devices and firmware that may require changes to your Nerves projects:

* Firmware images are cryptographically signed (both NervesHub and devices validate signatures)
* Devices are identified by a unique serial number

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

#### Certificate device authentication

_Important: This is recommended for production device fleets._

The following example shows how to configure NervesHubLink to use certificates for device authentication:

```elixir
config :nerves_hub_link,
  device_api_host: "your.nerveshub.host",
  ssl: [
    cert: "some_cert_der",
    key: "path/to/keyfile"
  ]
```

You can also provide your own options to use for the NervesHub socket connection via the `:socket` and `:ssl` keys, which are forwarded on to `phoenix_client` when creating the socket connection (see [`PhoenixClient.Socket` module](https://github.com/mobileoverlord/phoenix_client/blob/main/lib/phoenix_client/socket.ex#L57-L91) for support options.

Any [valid Erlang ssl socket option](http://erlang.org/doc/man/ssl.html#TLS/DTLS%20OPTION%20DESCRIPTIONS%20-%20COMMON%20for%20SERVER%20and%20CLIENT) can go in the `:ssl` key.

#### Shared secret device authentication (experimental)

_Important: Shared Secret authentication is a new feature under active development._

Shared Secrets use [HMAC](https://en.wikipedia.org/wiki/HMAC) cryptography to generate an authentication token used during websocket connection.

This has been built with simple device registration in mind, an ideal fit for hobby projects or projects under early R&D.

You can generate a key and secret in your NervesHub Product settings which you then include in your NervesHubLink settings.

A full example config:

```elixir
config :nerves_hub_link,
  configurator: NervesHubLink.Configurator.SharedSecret,
  device_api_host: "your.nerveshub.host",
  socket: [
    shared_secret: [
      product_key: "<product_key>",
      product_secret: "<product_secret>",
    ]
  ]
```

#### NervesKey (with cert based auth)

If your project is using [NervesKey](https://github.com/nerves-hub/nerves_key), you can tell `NervesHubLink` to read those certificates and key from the chip and assign the SSL options for you by enabling add it as a dependency:

```elixir
def deps() do
  [
    {:nerves_key, "~> 1.2"}
  ]
end
```

NervesKey will default to using I2C bus 1 and the `:primary` certificate pair (`:primary` is one-time configurable and `:aux` may be updated).  You can customize these options to use a different bus and certificate pair:

```elixir
config :nerves_hub_link, :nerves_key,
  certificate_pair: :aux,
  i2c_bus: 0
```

```elixir
config :nerves_hub_link,
  device_api_host: "your.nerveshub.host"
```

### Runtime configuration

`NervesHubLink` also supports runtime configuration via the `NervesHubLink.Configurator` behavior. This is called during application startup to build the configuration that is to be used for the connection. When implementing the behavior, you'll receive the initial default config read in from the application environment and you can modify it however you need.

This is useful for cases like:
- selectively choosing which cert/key to use
- reading a file stored on the device which isn't available during compilation

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

### Workflow examples

#### Creating a NervesHub product

A NervesHub product groups devices that run the same kind of firmware. All devices and firmware images have a product. NervesHub provides finer grain mechanisms for grouping devices, but a product is needed to get started.

By default, NervesHub uses the `:app` name in your `mix.exs` for the product name. If you would like it to use a different name, add a `:name` field to your `Mix.Project.config()`. For example, NervesHub would use "My Example" instead of "example" for the following project:

```elixir
  def project do
    [
      app: :example,
      name: "My Example"
    ]
  end
```

For the remainder of this document, though, we will not use the `:name` field and simply use the product name `example`.

Create a new product on NervesHub by running:

```bash
mix nerves_hub.product create
```

#### Creating NervesHub firmware signing keys

NervesHub requires cryptographic signatures on all managed firmware. Devices receiving firmware from NervesHub validate signatures. Since firmware is signed before uploading to NervesHub, NervesHub or any service NervesHub uses cannot modify it.

Firmware authentication uses [Ed25519 digital signatures](https://en.wikipedia.org/wiki/EdDSA#Ed25519). You need to create at least one public/private key pair and copy the public key part to NervesHub and to devices. NervesHub tooling helps with both. A typical setup has multiple signing keys to support key rotation and "development" keys that are not as protected.

Start by creating a `devkey` firmware signing key pair:

```bash
mix nerves_hub.key create devkey
```

On success, you'll see the public key. You can confirm using the NervesHub web interface that the public key exists. Private keys are never sent to the NervesHub server. NervesHub requires valid signatures from known keys on all firmware it distributes.

While not shown here, you can export keys for safe storage. Additionally, key creation and firmware signing can be done outside of the `mix` tooling.

When your Nerves device connects to NervesHub it will request all public firmware signing keys. You can override this behaviour by specifying the firmware signing keys your device should use in the config. If any keys are specified, keys will not be requested by the device. You specify a default key in the settings as well as opting-in to NervesHub sending all current publich keys available.

Defining keys to be used:

```elixir
config :nerves_hub_link,
  fwup_public_keys: [
    "bM/O9+ykZhCWx8uZVgx0sU3f0JJX7mqnAVU9VGeuHr4="
  ]
```

Defining keys to be used, and opting-in for updates:

```elixir
config :nerves_hub_link,
  request_fwup_public_keys: true,
  fwup_public_keys: [
    "bM/O9+ykZhCWx8uZVgx0sU3f0JJX7mqnAVU9VGeuHr4="
  ]
```

#### Publishing firmware

Uploading firmware to NervesHub is called publishing. To publish firmware start by calling:

```bash
mix firmware
```

Firmware can only be published if has been signed. You can sign the firmware by running.

```bash
mix nerves_hub.firmware sign --key devkey
```

Firmware can also be signed while publishing:

```bash
mix nerves_hub.firmware publish --key devkey
```

#### Initializing devices

*This step is not required for Shared Secret authentication*

In this example we will create a device with a hardware identifier `1234`.  The device will also be tagged with `qa` so we can target it in our deployment group. We will select `y` when asked if we would like to generate device certificates. Device certificates are required for a device to establish a connection with the NervesHub server. However, if you are using [NervesKey](https://github.com/nerves-hub/nerves_key), you can select `n` to skip generating device certificates.

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

It is important to note that device certificate private keys are generated and stay on your host computer. A certificate signing request is sent to the server, and a signed public key is passed back. Generated certificates will be placed in a folder titled `nerves-hub` in the current working directory. You can specify a different location by passing `--path /path/to/certs` to NervesHubCLI mix commands.

NervesHub certificates and hardware identifiers are persisted to the firmware when the firmware is burned to the SD card. To make this process easier, you can call `nerves_hub.device burn IDENTIFIER`. In this example, we are going to burn the firmware and certificates for device `1234` that we created.

```bash
mix nerves_hub.device burn 1234
```

Your device will now connect to NervesHub when it boots and establishes an network connection.

#### Creating deployments

Deployments associate firmware images to devices. NervesHub won't send firmware to a device until you create a deployment. First find the UUID of the firmware. You can list the firmware on NervesHub by calling:

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

Here we create a new deployment called `qa_deployment`. In the conditions of this deployment we left the `version condition` unspecified and the `tags` set to only `qa`.  This means that in order for a device to qualify for an update, it needs to have at least the tags `[qa]` and the device can be coming from any version.

At this point we can try to update the connected device.

Start by bumping the application version number from `0.1.0` to `0.1.1`. Then, create new firmware:

```bash
mix firmware
```

We can publish, sign, and deploy firmware in a single command now.

```bash
mix nerves_hub.firmware publish --key devkey --deploy qa_deployment
```

## Advanced features

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
