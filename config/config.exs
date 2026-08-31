import Config

# This config.exs file will configure `nerves_hub_link` to point to a local instance
# of `nerves_hub_web`. See CONTRIBUTING.md for details.

# `crash_reason` is what the runtime attaches when a process dies, and what
# `NervesHubLink.Extensions.ErrorReports.Handler` reads to decide a log event
# is an error worth reporting.
#
# This line is here for `mix credo`, which CI runs and which fails without it.
# `Credo.Check.Warning.MissedMetadataKeyInLoggerConfig` flags any metadata key
# passed to `Logger` that the formatter is not configured to print, on the
# grounds that it would silently never appear. That is a near miss here: the
# key is passed so a handler can read it rather than to be printed, which the
# check has no way to tell.
#
# It belongs in this file rather than `config/test.exs`, even though only tests
# pass the key by hand. Credo runs under `MIX_ENV=dev` and reads the formatter
# config of whichever environment it is running in, so a test-only declaration
# is invisible to it.
config :logger, :default_formatter, metadata: [:crash_reason]

import_config("#{Mix.env()}.exs")
