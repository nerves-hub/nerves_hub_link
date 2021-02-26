# Changelog

## 0.10.0-rc.0

* Enhancements
  * Use [`:slipstream`](https://github.com/NFIBrokerage/slipstream) for websocket
  connections
  * Report `device_api_version` in web connections
  * Optional `NervesHubLink.Client.reboot/0` callback behavior

* Fixes
  * Check `firmware_url` is valid before attempting update
  * set default `fwup_devpath` in the config

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
