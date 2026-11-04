# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.WebSocketServer do
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

  `:upgrade_after_msec` holds an `:upgrade` open for that long before
  answering, announcing `{:connection_test, :upgrade_requested}` first, so a
  test can act while the device is still connecting rather than racing it.
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
        case Keyword.get(opts, :upgrade_after_msec, 0) do
          0 ->
            :ok

          delay ->
            send(test_pid, {:connection_test, :upgrade_requested})
            Process.sleep(delay)
        end

        upgrade_adapter(
          conn,
          :websocket,
          {__MODULE__.Handler, [test_pid: test_pid], Keyword.take(opts, [:compress])}
        )

      :redirect ->
        send(test_pid, {:connection_test, :redirected})

        conn
        |> put_resp_header("location", Keyword.fetch!(opts, :location))
        |> send_resp(Keyword.get(opts, :status, 302), "")

      :refuse ->
        send_resp(conn, Keyword.get(opts, :status, 403), "")

      :silent ->
        send(test_pid, {:connection_test, :silent})
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
      send(test_pid, {:connection_test, {:server, self()}})

      {:ok, %{test_pid: test_pid}}
    end

    @impl WebSock
    def handle_in({payload, opcode: opcode}, state) do
      send(state.test_pid, {:connection_test, {:frame, opcode, payload}})

      {:ok, state}
    end

    @impl WebSock
    def handle_control({payload, opcode: opcode}, state) do
      send(state.test_pid, {:connection_test, {:frame, opcode, payload}})

      {:ok, state}
    end

    @impl WebSock
    def handle_info({:send_frame, frame}, state), do: {:push, frame, state}

    def handle_info({:close, code}, state), do: {:stop, :normal, code, state}

    def handle_info(_message, state), do: {:ok, state}

    @impl WebSock
    def terminate(_reason, state) do
      send(state.test_pid, {:connection_test, :terminated})

      :ok
    end
  end
end
