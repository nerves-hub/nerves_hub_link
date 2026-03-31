# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.DoneNotDonePlug do
  @moduledoc """
  Simulates a scenario where Mint sends :done before all bytes are received.

  Request 1 (retry 0): Sends Content-Length: 4096, streams 2048 bytes of <<0>>,
  then errors to close the connection.

  Request 2 (retry 1): Uses chunked transfer encoding (no Content-Length header).
  Sends only 1024 bytes of <<1>>, then returns normally. Bandit sends the chunked
  terminator causing Mint to emit :done even though downloaded_length (3072) does
  not match content_length (4096).

  Request 3 (retry 2): Sends the remaining 1024 bytes of <<1>> to complete the
  download.
  """

  @behaviour Plug

  import Plug.Conn

  @content_length 4096

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _opts) do
    retry_number = find_x_retry_number_header(conn.req_headers)

    case retry_number do
      0 ->
        # First request: advertise full content length, send half, then error
        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-length", to_string(@content_length))
        |> send_chunked(200)
        |> do_chunk(:binary.copy(<<0>>, 2048))
        |> force_close()

      1 ->
        # Retry: uses chunked transfer encoding (no content-length header).
        # Mint will send :done after the chunked terminator, but we only send
        # 1024 bytes. The downloader has content_length=4096 from the first
        # request and downloaded_length will be 3072 — a mismatch.
        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> send_chunked(200)
        |> do_chunk(:binary.copy(<<1>>, 1024))

      _ ->
        # Final retry: send remaining 1024 bytes to complete the download
        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-length", "1024")
        |> send_chunked(200)
        |> do_chunk(:binary.copy(<<1>>, 1024))
    end
  end

  defp do_chunk(conn, data) do
    {:ok, conn} = chunk(conn, data)
    conn
  end

  defp force_close(conn) do
    # Calling send_resp on an already-chunked conn raises AlreadySentError.
    # Bandit catches this and closes the TCP connection, which is what we want.
    send_resp(conn, 500, "Error")
  end

  defp find_x_retry_number_header([{"x-retry-number", retry_number} | _]),
    do: String.to_integer(retry_number)

  defp find_x_retry_number_header([_ | rest]), do: find_x_retry_number_header(rest)
  defp find_x_retry_number_header([]), do: raise("Could not find x-retry-number header")
end
