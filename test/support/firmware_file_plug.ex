# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.FirmwareFilePlug do
  @moduledoc """
  Serves a firmware file from disk.

  Unlike `NervesHubLink.Support.FWUPStreamPlug`, which builds a fresh unsigned
  firmware on every request, this plug serves a specific file so that tests can
  control how the firmware was built and signed.

      Utils.supervise_plug(FirmwareFilePlug, path: "/tmp/signed.fw")
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    send_file(conn, 200, Keyword.fetch!(opts, :path))
  end
end
