defmodule NervesHubLink.Support.IdleTimeoutPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _opts) do
    retry_number = find_x_retry_number_header(conn.req_headers)

    # gets incremented every retry, so doing it on 0 should only
    # sleep on the first connect
    # (something something stateless http....)
    if retry_number == 0 do
      Process.sleep(500)
    end

    send_resp(conn, 200, "content")
  end

  defp find_x_retry_number_header([{"x-retry-number", retry_number} | _]),
    do: String.to_integer(retry_number)

  defp find_x_retry_number_header([_ | rest]), do: find_x_retry_number_header(rest)
  defp find_x_retry_number_header([]), do: raise("Could not find x-retry-number header")
end
