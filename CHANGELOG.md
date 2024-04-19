# Changelog

## unreleased

* Added
  * [NervesTime](https://hex.pm/packages/nerves_time) has been added as a dependency.
  * Download current firmway signing keys on device connection. If no public firmware signing keys are defined if your config, NervesHubLink will request them from NervesHub when establishing a connection.

* Updated
  * `:public_key` CA certificates are used by default. If [CAStore](https://hex.pm/packages/castore) is included in your project it will be preferred.

## [2.2.0] - 2024-03-18

This update includes Archives, which is an extra fwup file that is downloaded as part
of a deployment. This allows you to send an update for something smaller than the whole
firmware. Archives are validated with separate public keys for safety.

* Added
  * Archive downloading and processing for extra packages

## [2.1.1] - 2024-02-05

* Fixed
  * `UploadFile` stream changed to be backwards compatible with Elixir 1.16 and older

## [2.1.0] - 2024-02-05

This update should be relatively safe and backwards compatible. It introduces some
new features with NervesHub including Pre-shared key authentication and file
upload/download ability through the console channge. If you were previously
relying on `NervesHubLink.Connection` functions then you will need to review
and update your code to use `NervesHubLink` connection functions instead.

* Removed
  * `NervesHubLink.Connection` was removed in favor is using the connection
    state of the socket instead.

* Added
  * Use the console channel to save files to the device (#131)
  * Send a file to an attached NervesHub web console (#130)
  * Pre-shared key authentication as an alternative to certificate authentication

* Updated
  * Default SNI from host if none specified
  * Default to CAStore when no `:ca_certs` are provided

## [2.0.0] - 2023-08-22

The new release of NervesHubLink starts adding new features from NervesHub 2.0, such as identifying the device you have open in NervesHub and hooks to help prevent a thundering herd of device reconnects. It also cleans up the code base a bit by removing unused packages. Make sure to run mix deps.unlock --unused after updating to keep your lock file up to date.

* Removed
  * NervesHubCLI and NervesHubCAStore as dependencies
  * NervesHubLinkCommon as dependencies, it was merged into this repo

* Added
  * Identify callback from NervesHub, a new message from the server that
    will let you blink an LED or anything else that will help you identify
    the device you're looking at is the one you have open in NervesHub.
  * Add a client callback for changing the backoff timeouts on reconnects
    (#128)

## [1.4.1] - 2023-05-26

* Added
  * Expose `NervesHubLink.console_active?` for checking active IEx sessions (#123)
  * Improvements for Elixir 1.15 and OTP 26

* Fixed
  * Stops IEx process with `:normal` instead of causing a crash (#121)

## [1.4.0] - 2022-10-07

* Fixed
  * Default to TLS 1.2 for all connections. This fixes issues if TLS 1.3 is
    used or attempted. See [NervesHubWeb: Potential SSL Issues](https://github.com/nerves-hub/nerves_hub_web#potential-ssl-issues)
    for more information.

## [1.3.0] - 2022-09-06

* Fixed
  * Use `Slipstream.push/5` for safe publishing
  * Don't apply update by default if the UUID is the same

## [1.2.0] - 2022-05-13

* `:nerves_hub_link_common 0.4.0`

* Removed
  * Elixir 1.10 is no longer supported. This matches the minimum version of
    `nerves_hub_link_common` which is Elixir 1.11

* Fixed
  * Allow for `:slipstream ~> 1.0`

## [1.1.0] - 2021-12-09

* Removed
  * Elixir 1.8 and 1.9 are no longer supported. These hadn't been tested on CI
    and were removed when we started testing Elixir 1.13.

* Added
  * Retry timeouts are now being set on Slipstream via the
    `:reconnect_after_msec` parameter.  The timeouts start at 1 second and
    double up to 60 seconds plus a random amount of jitter. Previously the
    timeouts started under a second and maxed out at 5 seconds without jitter.
    These timeouts were chosen to reduce the load on NervesHub servers when
    large numbers of devices disconnect. They can be overridden.

## [1.0.1] - 2021-11-16

* Fixed
  * A crash in the remote console would occur if a window resize message was received
    before the IEx process was started

## [1.0.0] - 2021-10-25

This release only bumps the version number. It doesn't have any code changes.

## [0.13.1] - 2021-10-19

* Fixed
  * `NervesHubLink.reconnect/0` no longer times out and instead disconnects
    the socket forcing the reconnection logic

## [0.13.0] - 2021-10-01

### Potentially Breaking

* Added
  * Switch the websocket client to the [Slipstream](https://github.com/NFIBrokerage/slipstream)
    library for communication with NervesHub. There are no API changes. This should only be
    a change to the internals, but you may notice timing differences especially around retries.

## [0.12.1] - 2021-08-19

* Added
  * `NervesHubLink.reconnect/0` to force reconnection of the socket and channels

## 0.12.0

* fwup 1.0.0

* Enhancements
  * added `:fwup_env` option to the Configurator to support
    environment variables which are needed in `fwup`

## 0.11.0

* Breaking Changes
  * This release includes a change to how CA certificates are used in the connection
    to NervesHub. If you are connecting to the publicly hosted https://nerves-hub.org,
    then no changes are required.
    If you are manually supplying `:ca_certs` config value to connect to another instance
    of NervesHub, then you will need to update you config following the instructions of
    [CA Certificates](https://hexdocs.pm/nerves_hub_link/readme.html#ca-certificates) in the README.

## 0.10.2

* Fixes
  * Fix issue that allowed unresolved atom keys in `:fwup_public_keys`
    config which would break firmware updates by failing to validate
    the public key
  * Add missing dependency on `:inets`

## 0.10.1

* Fixes
  * Fix typo that would cause the device to fail to reboot after applying
    an update

## 0.10.0

* `nerves_hub_link_common 0.2.0`

* Potential Breaking Changes
  * This enforces the update data structure exchanged between device and server
    and is mostly internal. However, if you implement your own `NervesHubLink.Client`
    behavior, then you will need to your `NervesHubLink.Client.update_available/1` to
    accept a `%NervesHubLink.Message.UpdateInfo{}` struct as the parameter
    instead of a map with string keys which was used until this point.

* Enhancements
  * Report API version to NervesHub. While there's currently only one version of
    the Device API, this is anticipation that we may want to change it in the future.
  * On reconnect, notify NervesHub of firmware currently being downloaded so
    that NervesHub can differentiate failed firmware updates from network hiccups.
  * Allow devices to implement their own reboot logic by implementing the
    `NervesHubLink.Client.reboot/0` callback

* Fixes
  * Check `firmware_url` is valid before attempting update

## 0.9.4

* Enhancements
  * Supports resuming failed downloads by offloading the responsibility of downloading
  and applying updates to a new package: `nerves_hub_link_common`

## v0.9.3

* Fixes
  * Fixes misleading default error message report
  * Ensures `:nerves_key` is started before use to deal with optional dependency
  start order bug

## v0.9.2

* Enhancements
  * Supports incoming `window_size` message from web channel to change the TTY size

## v0.9.1

* Enhancements
  * Send fwup version to server when connecting. This is required If you are using patchable firmware updates.

## v0.9.0

This release supports the new NervesHub console terminal. After upgrading,
remote sessions should look almost the same as `ssh`-based ones: tab-completion,
colors, and commandline history work as expected now.

## v0.8.2

* Bug Fixes
  * Fixes a broken call to `handle_fwup_message` on fwup success (thanks @bmteller! :heart:)

## v0.8.1

* Enhancements
  * Flatten console data being sent to NervesHub
  * Log all fwup progress percentage messages

## v0.8.0

* `nerves_hub_cli -> 0.10.0` - This decouples the CLI from the deprecated `:nerves_hub`
lib and frees this lib to do the same. If you are setting `:nerves_hub, org: org` in
your config, compilation will fail until you change it to use this lib key:

```elixir
config :nerves_hub_link, org: org
```
* `nerves_hub_user_api -> 0.6.0`

* Enhancements
  * Updates example app
  * Cleanup and structural changes
  * The default NervesHub certificates are no longer stored in the `priv` directory so
  if you're not using them, they won't be included.

* Fixes
  * Fixes an issue where a device may get an update message from the server while
  performing an update which would cause things to crash.
  * decouples `:nerves_hub` config values - see note above

## v0.7.6

Various cleanup and structure changes

* Enhancements
  * Add `Configurator` behavior - Gives the user a chance to do some configuration at runtime
  * `:nerves_key` as optional dep

## v0.7.5

* Bug fixes
  * Check NervesKey is provisioned before attempting to use it

## v0.7.4

* Enhancements
  * Rename to `NervesHubDevice`
  * Remove `HTTP` support to use channels exclusively
  * Reorganize as a an `Application` and remove ability to start a supervisor separately
  * Support using `NervesKey` via a configuartion flag

## v0.7.3

* Bug fixes
  * Fix a NervesHub remote console issue due to missing `:io_request` handling

* Enhancements
  * Add support for querying the NervesHub connection state so that this is
    easier to plug into Erlang's heart callback. This makes it possible to have
    a device automatically reboot if it can't reach NervesHub for a long
    time as a last ditch attempt at recovery. This has to be hooked up.

## v0.7.2

* Enhancements
  * Report firmware update progress so it can be monitored on NervesHub.

## v0.7.1

* Bug fixes
  * Handle firmware download connection timeout to fail more quickly when
    connections fail

## v0.7.0

* New features
  * Support remote IEx access from authorized NervesHub users, but only if
    enabled. To enable, add `config :nerves_hub, remote_iex: true` to your
    `config.exs`

## v0.6.0

* New features
  * Support remote reboot request from NervesHub

* Bug fixes
  * Fix decoding of private key from KV

## v0.5.1

* Bug fixes
  * Increased download hang timeout to deal with slow networks and <1 minute
    long hiccups
  * Fixed naming collision with a named process

## v0.5.0

* Enhancements
  * nerves_hub_cli: Bump to v0.7.0
  * The Phoenix Channel connection no longer uses the topic `firmware:firmware_uuid`
    and instead connects to the topic `device`.

## v0.4.0

This release has backwards incompatible changes so please read carefully.

The configuration key for firmware signing keys has changed from `:public_keys`
to `:fwup_public_keys`.

If you are not using nerves-hub.org for your NervesHub server, the configuration
keys for specifying the device endpoint for the server have changed. Look for
`:device_api_host` and `:device_api_port` in the documentation and example for
setting these.

* Enhancements
  * All firmware metadata is now passed up to the NervesHub. This will make it
    possible for the server to make decisions on firmware that has been loaded
    outside of NervesHub or old firmware that has been unloaded from NervesHub.
  * Code cleanup and refactoring throughout. More passes are planned.

## v0.3.0

* Enhancements
  * Add uuid and dn to http headers for polling requests

* Bug fixes
  * Fix crash when no updates were available

## v0.2.1

* Bug fixes
  * Use CA certificates from `:nerves_hub` instead of `:nerves_hub_core`.

## v0.2.0

* Enhancements
  * Updated docs.
  * Added support for [NervesKey](https://github.com/nerves-hub/nerves_key).
  * Added support for performing conditional updates.
  * Include `fwup` elixir dependency for interfacing with `fwup`.
  * Update deps and code to make it possible to run on host for testing.
  * Automatically call `NervesHub.connect()` instead of requiring it to be specified.
  * Improved error handling and reporting.

## v0.1.0

Initial release
