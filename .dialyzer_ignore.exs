[
  # `Mint.HTTP.t()` is a plain alias for `Mint.HTTP1.t() | Mint.HTTP2.t() |
  # Mint.UnsafeProxy.t()`, and each of those is still opaque. Handing the
  # connection `Mint.HTTP.connect/4` returns straight back to `Mint.HTTP`
  # therefore looks, to dialyzer on OTP 27, like passing an opaque term outside
  # the module that owns it. Nothing here reaches into the connection - it is
  # only ever passed back to Mint - and OTP 28 doesn't report it.
  {"lib/nerves_hub_link/downloader.ex", :call_with_opaque},
  # `Mint.WebSocket.new/4` only succeeds when the connection carries the nonce
  # that `Mint.WebSocket.upgrade/5` put in its private store, and dialyzer
  # cannot see it there. It therefore reads `new/4`'s success branch as
  # unreachable and `NervesHubLink.Connection`'s match on `{:ok, conn, websocket}`
  # as dead code. A minimal, fully typed call to `new/4` reports the same
  # thing, so this is upstream type information rather than anything here, and
  # the upgrade it supposedly cannot complete is exercised by every test in
  # `NervesHubLink.ConnectionTest`. Neither a spec on the calling function nor one
  # on a wrapper module shifts it: dialyzer narrows a declared return to what
  # it inferred, so the warning follows the code that matches on success.
  {"lib/nerves_hub_link/connection.ex", :pattern_match},
  # The same opaque-connection problem as the downloader above, where
  # `NervesHubLink.Connection` hands the connection to `Mint.WebSocket.upgrade/5`.
  # Reported on the OTP in `.tool-versions` and not on OTP 28, so which of
  # these two connection entries is doing any work depends on the OTP being used.
  {"lib/nerves_hub_link/connection.ex", :call_with_opaque}
]
