# Configuration

## Supervision

By default `:nerves_hub_link` is an OTP application that starts
`NervesHubLink.Supervisor` automatically and builds its configuration from the
application environment (i.e. your `config.exs`). This is the historical
behaviour and requires no changes.

If you'd prefer to own the connection's lifecycle - for example to start it
only after some runtime setup, or to build the configuration programmatically —
you can opt out of the automatic startup:

```elixir
config :nerves_hub_link, start: :manual
```

With `start: :manual`, the application starts nothing on boot. Instead, add
`NervesHubLink.Supervisor` to your own supervision tree:

```elixir
children = [
  # ...
  NervesHubLink.Supervisor
]
```

When started without options, the supervisor still builds its configuration
from the application environment via `NervesHubLink.Configurator.build/0`, so
`config :nerves_hub_link, ...` keeps working. To pass configuration explicitly
instead, provide a `NervesHubLink.Configurator.Config` struct:

```elixir
children = [
  {NervesHubLink.Supervisor, config: MyApp.build_nh_config()}
]
```

The default (`start: :auto`) and the manual mode share the same code path, so
switching between them does not change how the connection is configured — only
who is responsible for starting it.

## Runtime configuration

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

## Retrying firmware downloads

Firmware and Archive downloads are resilient to network issues and can be retried automatically.

You can configure how the Downloader handles timeouts, disconnections, and other aspects of the
retry logic by adding the following configuration to your application's config file:

```elixir
config :nerves_hub_link, :retry_config,
  max_disconnects: 20,
  idle_timeout: 75_000,
  max_timeout: 10_800_000
```

For more information about the configuration options, see the `NervesHubLink.Downloader.RetryConfig` module.

## Choosing how firmware is downloaded and applied

`NervesHubLink` ships three update strategies. Each one downloads the firmware
and hands it to `fwup`, but they differ in what they do with the bytes on the
way through, and therefore in what an interrupted update costs.

| Strategy | Firmware on disk | Survives a restart | Verifies the download |
| --- | --- | --- | --- |
| `NervesHubLink.UpdateManager.StreamingUpdater` (default) | none | no | `fwup` signature check only |
| `NervesHubLink.UpdateManager.CachingUpdater` | the whole file | resumes from the size of the partial file | `fwup` signature check only |
| `NervesHubLink.UpdateManager.PartsUpdater` | one file per part | resumes from the last verified part | every part, as it arrives |

The default streams straight into `fwup`, which needs no spare storage but
starts again from nothing whenever a download is interrupted.

`CachingUpdater` keeps the download so it can be resumed, and trusts the size of
what it already has. A part that was half written when the power went out is
treated as good and only shows up much later as an `fwup` error.

`PartsUpdater` checks each part against the checksums NervesHub sends in the
update payload, so a part that arrives corrupted is downloaded again on the
spot, and a device that restarts mid-update keeps the parts it had already
verified. This is the one to pick for devices on slow or unreliable connections.
It needs a NervesHub server new enough to send `partials_checksums`; older
servers fall back to a single unverified download with a warning.

```elixir
config :nerves_hub_link,
  updater: NervesHubLink.UpdateManager.PartsUpdater

config :nerves_hub_link, NervesHubLink.UpdateManager.PartsUpdater,
  cache_dir: "/data/nerves_hub_link/firmware",
  part_size: 1_048_576,
  max_part_attempts: 3,
  max_concurrent_parts: 1
```

`PartsUpdater` can also download from several connections at once. Raising
`:max_concurrent_parts` divides the parts still needed into that many contiguous
ranges and fetches each one separately, which helps on links where a single
connection can't fill the available bandwidth, such as high latency satellite or
cellular. It costs a connection per range on the device *and* on whatever is
serving the firmware, multiplied by every device in a deployment, so it stays at
`1` unless you raise it.

See `NervesHubLink.UpdateManager.PartsUpdater` and
`NervesHubLink.UpdateManager.CachingUpdater` for the options each one takes, and
`NervesHubLink.UpdateManager.Updater` for writing your own.

## Conditionally applying updates

It's not always appropriate to apply a firmware update immediately. Custom logic can be added to the device by
implementing the `NervesHubLink.Client` behaviour and telling NervesHubLink to use it. eg.

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

To have NervesHubLink use it, update your `config.exs` as follows:

```elixir
config :nerves_hub_link, client: MyApp.NervesHubLinkClient
```

## Reporting update progress

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

## Enabling remote IEx access

It's possible to remotely log into your device via the NervesHub web interface. This feature is disabled by default. To enable, add the following to your `config.exs`:

```elixir
config :nerves_hub_link, remote_iex: true
```

The remote IEx process is started on the first data request from NervesHub and is terminated after 5 minutes of inactivity. You can adjust this by setting `:remote_iex_timeout` value in seconds in your `config.exs`:

```elixir
config :nerves_hub_link, remote_iex_timeout: 900 # 15 minutes
```

You may also need additional permissions on NervesHub to see the device and to use the remote IEx feature.

## Alarms

This application can set and clear the following alarms:

- `NervesHubLink.Disconnected`
  - set: An issue is preventing a connection to NervesHub or one just hasn't been made yet
  - clear: Currently connected to NervesHub
- `NervesHubLink.UpdateInProgress`
  - set: A new firmware update is being downloaded or applied
  - clear: No updates are happening

## CA Certificates

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

Similarly, the downloader can be configured to use custom CA certificates to establish the HTTP connection to the firmware download location.

```elixir
my_der_list = [<<213, 34, 234, 53, 83, 8, 2, ...>>]
config :nerves_hub_link, downloader_ssl: [cacerts: my_der_list]
```

## HTTP proxy

Devices that have to reach NervesHub through an HTTP proxy can configure one for both the WebSocket connection and the firmware downloader. The option is passed through to `Mint.HTTP.connect/4` as `:proxy`, so any `Mint` proxy form is accepted:

```elixir
proxy = {:http, "proxy.example.com", 8080, []}

config :nerves_hub_link,
  socket: [http_opts: [proxy: proxy]],
  downloader_http_opts: [proxy: proxy]
```

`http_opts` (under `:socket`) and `:downloader_http_opts` forward any extra options that `Mint.HTTP.connect/4` accepts — `:proxy_headers`, `:hostname`, etc. They merge on top of the SSL configuration described above, so you can combine them:

```elixir
config :nerves_hub_link,
  ssl: [cacerts: my_der_list],
  socket: [http_opts: [proxy: {:http, "proxy.example.com", 8080, []}]]
```

## Message serialization

Messages between the device and NervesHub are encoded as JSON by default. Devices on metered or low bandwidth connections can use [Msgpack](https://msgpack.org) instead, which encodes the same messages in fewer bytes and uses less memory doing it.

Msgpack needs the [`msgpax`](https://hex.pm/packages/msgpax) library, which is an optional dependency:

```elixir
def deps() do
  [
    {:msgpax, "~> 2.0"}
  ]
end
```

and then:

```elixir
config :nerves_hub_link, serializer: :msgpack
```

> #### Your server has to support it too {: .warning}
>
> The device requests the Msgpack protocol when it connects. A NervesHub server that doesn't support it will reject the connection, and a device that can't connect can't be sent the firmware that would change this setting back. Confirm your server supports Msgpack before rolling this out to a fleet.

If `:msgpax` is missing, or the configured serializer isn't one it knows, the device logs an error and connects with JSON rather than dropping off the network.

Note that the two formats don't put identical bytes on the wire for every value. Most notably, Msgpack carries timestamps — such as the one in a health report — as its own extension type, where JSON sends an ISO 8601 string.

## Verifying network availability

`NervesHubLink` will attempt to verify that the network is available before initiating the first connection attempt. This is done by checking if the `NervesHub` host address (`config.host`) can be resolved. If the network isn't available then the check will be run again in 2 seconds.

You can disable this behaviour with the following config:

```elixir
config :nerves_hub_link, connect_wait_for_network: false
```

## Providing additional fwup arguments

To pass additional arguments supported by the fwup CLI, you can pass a list of strings via the `:fwup_extra_options` key.

```elixir
config :nerves_hub_link, fwup_extra_options: ["--unsafe"],
```

## Disable `NervesHubLink` during testing

To disable `NervesHubLink` connecting to `NervesHub` when testing, you can add:

```elixir
config :nerves_hub_link, connect: false
```

to your `config/test.exs`
