# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.ResumedRangePlug do
  @moduledoc """
  Serves a 4096 byte file to a download that is resuming from part way through
  it, and cuts the first response short so the download has to come back for
  the rest.

  Every request's `Range` header is forwarded to `:test_pid` as
  `{:range, retry_number, first_byte}`, so a test can check that a resumed
  download asks for offsets into the file rather than offsets into the request
  that was interrupted.
  """

  @behaviour Plug

  import Plug.Conn

  @content_length 4096

  @doc "The size of the file this plug serves"
  @spec content_length() :: pos_integer()
  def content_length(), do: @content_length

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    retry_number = conn |> header("x-retry-number") |> String.to_integer()
    first = range_start(conn)

    send(opts[:test_pid], {:range, retry_number, first})

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header(
        "content-range",
        "bytes #{first}-#{@content_length - 1}/#{@content_length}"
      )
      |> put_resp_header("content-length", to_string(@content_length - first))
      |> send_chunked(206)

    # The first response is half of what it claimed to be, which is what the
    # download sees when a connection drops part way through a body.
    payload =
      if retry_number == 0 do
        :binary.copy(<<0>>, div(@content_length - first, 2))
      else
        :binary.copy(<<1>>, @content_length - first)
      end

    {:ok, conn} = chunk(conn, payload)

    if retry_number == 0, do: force_close(conn), else: conn
  end

  # Calling send_resp on an already-chunked conn raises AlreadySentError. Bandit
  # catches this and closes the TCP connection, which is what a dropped
  # connection looks like to the download.
  defp force_close(conn), do: send_resp(conn, 500, "Error")

  defp range_start(conn) do
    conn
    |> header("range")
    |> String.replace_prefix("bytes=", "")
    |> String.split("-")
    |> hd()
    |> String.to_integer()
  end

  defp header(conn, name) do
    case List.keyfind(conn.req_headers, name, 0) do
      {^name, value} -> value
      nil -> raise("Could not find the #{name} header")
    end
  end
end
