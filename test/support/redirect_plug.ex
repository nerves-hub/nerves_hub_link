# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.RedirectPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(%Plug.Conn{request_path: "/redirect"} = conn, port: port) do
    redirect = "http://localhost:#{port}/redirected"

    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("location", redirect)
    |> send_resp(302, redirect)
  end

  def call(%Plug.Conn{request_path: "/redirected"} = conn, _opts) do
    conn
    |> send_resp(200, "redirected")
  end
end
