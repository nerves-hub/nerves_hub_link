[
  # `Mint.HTTP.t()` is a plain alias for `Mint.HTTP1.t() | Mint.HTTP2.t() |
  # Mint.UnsafeProxy.t()`, and each of those is still opaque. Handing the
  # connection `Mint.HTTP.connect/4` returns straight back to `Mint.HTTP`
  # therefore looks, to dialyzer on OTP 27, like passing an opaque term outside
  # the module that owns it. Nothing here reaches into the connection - it is
  # only ever passed back to Mint - and OTP 28 doesn't report it.
  {"lib/nerves_hub_link/downloader.ex", :call_with_opaque}
]
