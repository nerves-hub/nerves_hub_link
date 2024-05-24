defmodule NervesHubLink.Support.HTTPErrorPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _opts) do
    send_resp(conn, 416, "Range Not Satisfiable")
  end
end
