[
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
  #
  # This is the only entry the OTP in `.tool-versions` needs. The opaque-term
  # entries that were here, for the connection being handed back to Mint, were
  # reported on OTP 27 and are not on OTP 29.
  {"lib/nerves_hub_link/connection.ex", :pattern_match}
]
