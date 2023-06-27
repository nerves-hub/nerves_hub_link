defmodule NervesHubLink.Support.FWUPStreamPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Fwup.TestSupport.Fixtures

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _opts) do
    {:ok, path} = Fixtures.create_firmware("test")

    conn
    |> send_file(200, path)
  end
end
