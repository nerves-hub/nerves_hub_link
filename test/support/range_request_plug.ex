defmodule NervesHubLink.Support.RangeRequestPlug do
  @moduledoc """
  Sends chunked response according to the value of the range-request header
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    {start, finish} = fetch_range_header(conn.req_headers)
    payload = "hello, world"
    resp = fetch_range(payload, start, finish)

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("content-length", to_string(byte_size(payload)))
      |> put_resp_header(
        "content-range",
        "bytes #{start}-#{finish}/#{to_string(byte_size(payload))}"
      )
      |> send_chunked(206)

    {:ok, conn} = chunk(conn, resp)
    halt(conn)
  end

  defp fetch_range(payload, start, finish) do
    {_, tail} = String.split_at(payload, start)
    fetch_range_until(tail, <<>>, start, finish)
  end

  defp fetch_range_until(_, acc, finish, finish) do
    acc
  end

  defp fetch_range_until(<<c::binary-size(1), rest::binary>>, acc, i, finish) do
    fetch_range_until(rest, acc <> c, i + 1, finish)
  end

  defp fetch_range_header([]), do: {0, 1}

  defp fetch_range_header([{"range", "bytes=" <> range} | _rest]) do
    [start, finish] = String.split(range, "-", parts: 2)
    {String.to_integer(start), String.to_integer(finish)}
  end

  defp fetch_range_header([_ | rest]), do: fetch_range_header(rest)
end
