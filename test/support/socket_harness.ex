# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.SocketHarness do
  @moduledoc """
  Lets a test play NervesHub to a real `NervesHubLink.Socket`.

  The socket connects over an actual websocket to a server in this test, so
  what these tests exercise is the device's half of the protocol as it goes
  over the wire: the upgrade, the joins, the frames in both directions.

  The helpers keep the shapes the previous ones had - `assert_push/3`,
  `push/4`, `assert_join/3`, `disconnect/2` - so what a test says stays about
  the protocol rather than about the plumbing. What changed is that payloads
  are now what JSON carries, so a map the device builds with atom keys arrives
  here with string keys and string values.

  Frames the socket sends that a test does not ask about are kept rather than
  insisted upon, so a test only names the messages it is actually about.
  """

  import ExUnit.Assertions

  # The specs here are for whoever writes the next test. They promise more than
  # these functions return - `await_joined/3` only ever returns `true` from the
  # wait it delegates to, say - which this project's `:underspecs` reads as a
  # contract claiming too much, so the contract check goes rather than the
  # documentation.
  @dialyzer :no_contracts

  alias NervesHubLink.Connection.Message
  alias NervesHubLink.Connection.Serializer.JSON
  alias NervesHubLink.Support.Utils
  alias NervesHubLink.Support.WebSocketServer

  @default_timeout 2_000

  defmacro __using__(_opts) do
    quote do
      import NervesHubLink.Support.SocketHarness
    end
  end

  @doc """
  Start a websocket server for this test, and return its port.
  """
  @spec start_server(keyword()) :: non_neg_integer()
  def start_server(opts \\ []) do
    {:ok, _pid, port} =
      Utils.supervise_plug(WebSocketServer, Keyword.put_new(opts, :test_pid, self()))

    port
  end

  @doc """
  Wait until the server side of the connection exists, and remember it.

  The socket is its own process, so this is how a test knows the device has
  finished connecting and which process to tell to send things.
  """
  @spec await_connect(timeout()) :: pid()
  def await_connect(timeout \\ @default_timeout) do
    # Liveness as well as presence: a socket that reconnects is served by a new
    # process, and the one remembered here died with the connection it served.
    case Process.get(:socket_harness_server) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: receive_server(timeout)

      nil ->
        receive_server(timeout)
    end
  end

  defp receive_server(timeout) do
    _ = assert_receive {:connection_test, {:server, pid}}, timeout
    _ = Process.put(:socket_harness_server, pid)

    pid
  end

  @doc """
  Wait until both ends agree the connection is up.

  `await_connect/1` only says the server has accepted the upgrade; the socket
  has its own copy of the answer still to read.
  """
  @spec await_connected(GenServer.server(), timeout()) :: :ok
  def await_connected(socket, timeout \\ @default_timeout) do
    _ = await_connect(timeout)

    eventually(
      fn -> NervesHubLink.Socket.check_connection(socket, :socket) end,
      timeout,
      "the socket to finish connecting"
    )

    :ok
  end

  @doc """
  Wait until the socket has taken in the reply to its join of `topic`.

  Replying to a join puts a frame on the wire; the socket has not joined
  anything until it has read that frame. Anything a test does to a topic
  before then is refused for not being joined.
  """
  @spec await_joined(GenServer.server(), atom(), timeout()) :: :ok
  def await_joined(socket, type, timeout \\ @default_timeout) do
    eventually(
      fn -> NervesHubLink.Socket.check_connection(socket, type) end,
      timeout,
      "the socket to finish joining #{type}"
    )
  end

  @doc """
  Assert something becomes true, rather than that it already is.

  A message from NervesHub now crosses a real socket, so what the socket does
  about one is not necessarily done the instant after it is sent. This is for
  asserting on the socket's own state; use `assert_push/3` for what it sends.
  """
  defmacro assert_eventually(expression, timeout \\ @default_timeout) do
    description = Macro.to_string(expression)

    quote do
      assert eventually(
               fn -> unquote(expression) end,
               unquote(timeout),
               unquote(description)
             )
    end
  end

  @doc false
  @spec eventually((-> as_boolean(term())), timeout(), String.t()) :: true
  def eventually(fun, timeout, description) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(fun, deadline, description)
  end

  defp do_eventually(fun, deadline, description) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{description}")

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline, description)
    end
  end

  @doc """
  Assert the socket sent `event` on `topic`, with a payload matching `pattern`.

  The payload is what JSON carried, so a map the device built with atom keys
  is matched here with string keys and string values.
  """
  defmacro assert_push(topic, event, pattern \\ quote(do: _)) do
    quote do
      message = await_frame(unquote(topic), unquote(event))

      assert unquote(pattern) = message.payload

      message
    end
  end

  @doc """
  Assert the socket asked to join `topic` with params matching `pattern`, and
  answer it.

  `reply` is `:ok` to accept, `{:ok, response}` to accept with something to
  say, or `:error` / `{:error, response}` to refuse.
  """
  defmacro assert_join(topic, pattern, reply) do
    quote do
      message = await_frame(unquote(topic), "phx_join")

      assert unquote(pattern) = message.payload

      answer_join(message, unquote(reply))

      message
    end
  end

  # Public only because the macro above expands into a call to it. Credo wants
  # the spec; dialyzer reads `Message.t()` as wider than the messages it is
  # ever handed, so the two are satisfied one each.
  @doc false
  @dialyzer {:nowarn_function, answer_join: 2}
  @spec answer_join(Message.t(), term()) :: :ok
  def answer_join(%Message{} = message, reply) do
    {status, response} =
      case reply do
        :ok -> {"ok", %{}}
        :error -> {"error", %{}}
        {:ok, response} -> {"ok", response}
        {:error, response} -> {"error", response}
      end

    server_reply(message, status, response)
  end

  @doc """
  Wait for a frame the socket sent on `topic` with `event`.

  Frames that do not match are kept, so a later call can still find them and
  a test need not name every message the socket sends.
  """
  @spec await_frame(String.t(), String.t(), timeout()) :: Message.t()
  def await_frame(topic, event, timeout \\ @default_timeout) do
    case take_kept(topic, event) do
      {:ok, message} ->
        message

      :error ->
        receive_frame(topic, event, System.monotonic_time(:millisecond) + timeout)
    end
  end

  @doc "Send a message to the socket, as NervesHub would."
  @spec server_push(String.t(), String.t(), term(), keyword()) :: :ok
  def server_push(topic, event, payload, opts \\ []) do
    message = %Message{
      topic: topic,
      event: event,
      payload: payload,
      ref: opts[:ref],
      join_ref: opts[:join_ref]
    }

    server_send(JSON.encode!(message))
  end

  @doc "Reply to a message the socket sent."
  @spec server_reply(Message.t(), String.t(), term()) :: :ok
  def server_reply(%Message{} = to, status, response \\ %{}) do
    server_push(to.topic, "phx_reply", %{"status" => status, "response" => response},
      ref: to.ref,
      join_ref: to.join_ref
    )
  end

  @doc "Send a raw frame to the socket."
  @spec server_send(WebSock.message()) :: :ok
  def server_send(frame) do
    send(await_connect(), {:send_frame, frame})

    :ok
  end

  @doc "Close the connection from NervesHub's end."
  @spec server_close(non_neg_integer()) :: :ok
  def server_close(code \\ 1000) do
    send(await_connect(), {:close, code})

    :ok
  end

  ## Frame bookkeeping

  defp receive_frame(topic, event, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("""
      timed out waiting for the socket to send #{topic}:#{event}.

      frames kept so far: #{inspect(kept())}
      """)
    end

    receive do
      {:connection_test, {:frame, opcode, payload}} when opcode in [:text, :binary] ->
        message = JSON.decode!(payload, opcode)

        if message.topic == topic and message.event == event do
          message
        else
          keep(message)
          receive_frame(topic, event, deadline)
        end
    after
      remaining ->
        flunk("""
        timed out waiting for the socket to send #{topic}:#{event}.

        frames kept so far: #{inspect(kept())}
        """)
    end
  end

  defp kept(), do: Process.get(:socket_harness_frames, [])

  defp keep(message), do: Process.put(:socket_harness_frames, kept() ++ [message])

  defp take_kept(topic, event) do
    frames = kept()

    case Enum.split_while(frames, &(not (&1.topic == topic and &1.event == event))) do
      {_before, []} ->
        :error

      {before, [message | rest]} ->
        Process.put(:socket_harness_frames, before ++ rest)
        {:ok, message}
    end
  end
end
