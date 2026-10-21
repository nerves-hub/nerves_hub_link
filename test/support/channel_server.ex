# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.ChannelServer do
  @moduledoc """
  A websocket server that does whatever a test needs it to.

  Everything it receives is forwarded to `:test_pid`, and it sends whatever
  that process tells it to, so a test can play the part of NervesHub down to
  the individual frame.

  `:mode` picks what it does with the upgrade request:

    * `:upgrade` (default) - accepts it
    * `:redirect` - answers 302 with `:location`
    * `:refuse` - answers `:status`, 403 by default
    * `:silent` - accepts the connection and never answers
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)

    case Keyword.get(opts, :mode, :upgrade) do
      :upgrade ->
        upgrade_adapter(
          conn,
          :websocket,
          {__MODULE__.Handler, [test_pid: test_pid], Keyword.take(opts, [:compress])}
        )

      :redirect ->
        conn
        |> put_resp_header("location", Keyword.fetch!(opts, :location))
        |> send_resp(Keyword.get(opts, :status, 302), "")

      :refuse ->
        send_resp(conn, Keyword.get(opts, :status, 403), "")

      :silent ->
        send(test_pid, {:channel_test, :silent})
        Process.sleep(:infinity)
        conn
    end
  end

  defmodule Handler do
    @moduledoc false

    @behaviour WebSock

    @impl WebSock
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:channel_test, {:server, self()}})

      {:ok, %{test_pid: test_pid}}
    end

    @impl WebSock
    def handle_in({payload, opcode: opcode}, state) do
      send(state.test_pid, {:channel_test, {:frame, opcode, payload}})

      {:ok, state}
    end

    @impl WebSock
    def handle_control({payload, opcode: opcode}, state) do
      send(state.test_pid, {:channel_test, {:frame, opcode, payload}})

      {:ok, state}
    end

    @impl WebSock
    def handle_info({:send_frame, frame}, state), do: {:push, frame, state}

    def handle_info({:close, code}, state), do: {:stop, :normal, code, state}

    def handle_info(_message, state), do: {:ok, state}

    @impl WebSock
    def terminate(_reason, state) do
      send(state.test_pid, {:channel_test, :terminated})

      :ok
    end
  end
end
