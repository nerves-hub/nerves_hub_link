defmodule NervesHubLink.Support.XRetryNumberPlug do
  @moduledoc """
  Plug sends data in chunks, halting halfway thru to be resumed by a client

  the payload sent is the value of the http header `X-Retry-Number` copied
  2048 times.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _opts) do
    retry_number = find_x_retry_number_header(conn.req_headers)

    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-length", "4096")
    |> send_chunked(200)
    |> do_stream(retry_number)
  end

  defp do_stream(conn, retry_number) do
    {:ok, conn} = chunk(conn, :binary.copy(<<retry_number::8>>, 2048))
    halt(conn)
  end

  # i have no idea why get_req_header/2 doesn't work here.
  defp find_x_retry_number_header([{"x-retry-number", retry_number} | _]),
    do: String.to_integer(retry_number)

  defp find_x_retry_number_header([_ | rest]), do: find_x_retry_number_header(rest)
  defp find_x_retry_number_header([]), do: raise("Could not find x-retry-number header")
end
