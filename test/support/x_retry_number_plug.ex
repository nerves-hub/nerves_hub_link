# SPDX-FileCopyrightText: 2023 Eric Oestrich
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.XRetryNumberPlug do
  @moduledoc """
  Plug sends data in chunks, halting halfway thru to be resumed by a client

  the payload sent is the value of the http header `X-Retry-Number` copied
  2048 times.
  """

  @behaviour Plug

  import Plug.Conn

  @content_length 4096

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _opts) do
    retry_number = find_x_retry_number_header(conn.req_headers)

    started_from = find_content_range_start_value(conn.req_headers)

    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_content_range_and_length(started_from)
    |> send_chunked(206)
    |> do_stream(retry_number, started_from)
  end

  defp do_stream(conn, retry_number, started_from) do
    cond do
      is_nil(started_from) ->
        {:ok, conn} = chunk(conn, :binary.copy(<<retry_number::8>>, 2048))
        halt(conn)

      started_from + 2048 == @content_length ->
        {:ok, conn} = chunk(conn, :binary.copy(<<retry_number::8>>, 2048))
        chunk(conn, "")

      true ->
        raise("we shouldn't be here")
    end
  end

  # i have no idea why get_req_header/2 doesn't work here.
  defp find_x_retry_number_header([{"x-retry-number", retry_number} | _]),
    do: String.to_integer(retry_number)

  defp find_x_retry_number_header([_ | rest]), do: find_x_retry_number_header(rest)
  defp find_x_retry_number_header([]), do: raise("Could not find x-retry-number header")

  defp find_content_range_start_value([{"range", "bytes=" <> values} | _]) do
    values
    |> String.split("-")
    |> hd()
    |> String.to_integer()
  end

  defp find_content_range_start_value([_ | rest]), do: find_content_range_start_value(rest)
  defp find_content_range_start_value([]), do: nil

  defp put_content_range_and_length(conn, nil) do
    put_resp_header(conn, "content-length", to_string(@content_length))
  end

  defp put_content_range_and_length(conn, starting_bytes) do
    put_resp_header(
      conn,
      "content-range",
      "bytes #{starting_bytes}-#{@content_length}/#{@content_length + 1}"
    )
    |> put_resp_header("content-length", to_string(@content_length - starting_bytes))
  end
end
