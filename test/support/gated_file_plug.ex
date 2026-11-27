# SPDX-FileCopyrightText: 2026 Benjamin Moss
# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.GatedFilePlug do
  @moduledoc """
  Serves a file from disk, but only once the test lets each request through,
  which holds a download open while the test makes something else happen.

  Every request sends `{:gated_request, tag, handler_pid}` to `:test_pid` and
  then waits for `:release`, to serve the file, or `:fail`, to answer with a 500
  and fail the download. A request nothing answers serves the file after five
  seconds, so a test that fails mid-gate doesn't leave the handler blocked.

  Options:

    * `:path` - the file to serve. Required.
    * `:test_pid` - the process told about each request. Required.
    * `:tag` - included in the message, to tell servers apart. Defaults to `nil`.
  """

  @behaviour Plug

  import Plug.Conn

  @release_timeout 5_000

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:gated_request, opts[:tag], self()})

    receive do
      :release -> send_file(conn, 200, Keyword.fetch!(opts, :path))
      :fail -> send_resp(conn, 500, "Internal Server Error")
    after
      @release_timeout -> send_file(conn, 200, Keyword.fetch!(opts, :path))
    end
  end
end
