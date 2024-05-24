defmodule NervesHubLink.Support.HTTPUnauthorizedErrorPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    send(opts[:report_pid], :request_error)

    send_resp(conn, 401, "Unauthorized")
  end
end
