# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.GatedFilePlug do
  @moduledoc """
  Serves a file from disk, but only once the test lets each request through.

  Every request sends `{:gated_request, tag, handler_pid}` to `:test_pid` and
  then waits for `:release` before sending anything back. That holds a download
  open, so a test can make something else happen while it's in progress.

  Options:

    * `:path` - the file to serve. Required.
    * `:test_pid` - the process told about each request. Required.
    * `:tag` - included in the message, to tell servers apart. Defaults to `nil`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:gated_request, opts[:tag], self()})

    receive do
      :release -> :ok
    end

    send_file(conn, 200, Keyword.fetch!(opts, :path))
  end
end
