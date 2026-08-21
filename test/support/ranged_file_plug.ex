# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.RangedFilePlug do
  @moduledoc """
  Serves a file, honouring `Range` requests the way the firmware storage
  NervesHub hands out URLs for does, and optionally corrupting part of what it
  sends.

  This is what lets a test watch an updater resume, and see what it does when
  the bytes it is given aren't the bytes it asked for.

  Options:

    * `:path` - the file to serve. Required.
    * `:test_pid` - sent `{:range_request, first, last}` for every request.
    * `:counter` - a `:counters` reference with at least two slots. The first
      counts every request, so a test can tell how many requests an update
      needed. The second is used for `:corrupt_requests`.
    * `:corrupt` - `{offset, length}`, a window of the file to flip the bits of
      before sending.
    * `:corrupt_requests` - how many of the requests that reach into the
      `:corrupt` window are corrupted, counting from the first. Requests that
      don't reach into it aren't counted, so this stays predictable when
      several requests are in flight at once. Requires `:counter`. Defaults to
      corrupting every request.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    contents = File.read!(Keyword.fetch!(opts, :path))
    total = byte_size(contents)

    case requested_range(conn, total) do
      {:ok, first, last} ->
        :ok = count_request(opts)

        if test_pid = opts[:test_pid] do
          send(test_pid, {:range_request, first, last})
        end

        body =
          contents
          |> binary_part(first, last - first + 1)
          |> maybe_corrupt(opts, first)

        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_content_type("application/octet-stream")
        |> send_range(first, last, total, body, ranged?(conn))

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{total}")
        |> send_resp(416, "")
    end
  end

  defp send_range(conn, _first, _last, _total, body, false), do: send_resp(conn, 200, body)

  defp send_range(conn, first, last, total, body, true) do
    conn
    |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
    |> send_resp(206, body)
  end

  defp ranged?(conn), do: not is_nil(List.keyfind(conn.req_headers, "range", 0))

  defp requested_range(conn, total) do
    case List.keyfind(conn.req_headers, "range", 0) do
      {"range", "bytes=" <> range} ->
        {first, last} = parse_range(range, total)
        if first >= total, do: :unsatisfiable, else: {:ok, first, min(last, total - 1)}

      _ ->
        {:ok, 0, total - 1}
    end
  end

  defp parse_range(range, total) do
    case String.split(range, "-", parts: 2) do
      [first, ""] -> {String.to_integer(first), total - 1}
      [first, last] -> {String.to_integer(first), String.to_integer(last)}
    end
  end

  defp count_request(opts) do
    case opts[:counter] do
      nil -> :ok
      counter -> :counters.add(counter, 1, 1)
    end
  end

  defp maybe_corrupt(body, opts, first) do
    case opts[:corrupt] do
      {offset, length} ->
        if overlaps?(first, byte_size(body), offset, length) and corrupt_now?(opts) do
          corrupt(body, first, offset, length)
        else
          body
        end

      _ ->
        body
    end
  end

  defp overlaps?(first, size, offset, length) do
    first < offset + length and offset < first + size
  end

  defp corrupt_now?(opts) do
    counter = opts[:counter]

    case Keyword.get(opts, :corrupt_requests, :infinity) do
      :infinity ->
        true

      _limit when is_nil(counter) ->
        true

      limit ->
        :ok = :counters.add(counter, 2, 1)
        :counters.get(counter, 2) <= limit
    end
  end

  defp corrupt(body, first, offset, length) do
    from = max(offset - first, 0)
    to = min(offset + length - first, byte_size(body))

    if from < to do
      binary_part(body, 0, from) <>
        flip_bits(binary_part(body, from, to - from)) <>
        binary_part(body, to, byte_size(body) - to)
    else
      body
    end
  end

  defp flip_bits(data), do: for(<<byte <- data>>, into: <<>>, do: <<bxor(byte, 0xFF)>>)
end
