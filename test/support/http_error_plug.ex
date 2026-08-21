# SPDX-FileCopyrightText: 2023 Eric Oestrich
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.HTTPErrorPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn.Status

  @default_status 416

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    status = Keyword.get(opts, :status, @default_status)

    send_resp(conn, status, Status.reason_phrase(status))
  end
end
