# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.ConnectionHarness do
  @moduledoc """
  Drives a `NervesHubLink.Connection` from a test process.

  The connection is a data structure, so the test process can be the process that
  owns it: it holds the connection, feeds the connection every message that
  arrives and collects the events that come back. That means these tests
  exercise the real connection - a real upgrade, real frames, real close -
  rather than a stand-in for one.

  The struct accumulates as the test goes: `events` is everything the connection
  has produced, and `frames` is everything the server has received.
  """

  import ExUnit.Assertions

  alias NervesHubLink.Connection
  alias NervesHubLink.Connection.Message
  alias NervesHubLink.Connection.Serializer.JSON
  alias NervesHubLink.Support.Utils
  alias NervesHubLink.Support.WebSocketServer

  defstruct [:connection, :server, :port, events: [], frames: []]

  @type t :: %__MODULE__{
          connection: Connection.t() | nil,
          server: pid() | nil,
          port: non_neg_integer() | nil,
          events: [Connection.event()],
          frames: [{atom(), binary()}]
        }

  # The struct fills in as a test goes, so a function that returns it part-way
  # built always returns something more specific than `t()`, which this
  # project's `:underspecs` reads as a spec promising too much. The specs here
  # are for whoever writes the next test, so they stay and the contract check
  # goes.
  @dialyzer :no_contracts

  @doc """
  Start a server and build a connection pointed at it, without connecting.

  `:server` is passed to `NervesHubLink.Support.WebSocketServer` and `:connection`
  to `NervesHubLink.Connection.new/1`.
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    server_opts = Keyword.get(opts, :server, [])
    port = start_server(server_opts)

    channel_opts =
      Keyword.merge(
        [
          uri: URI.parse("ws://localhost:#{port}/socket/websocket?vsn=2.0.0"),
          serializer: JSON,
          upgrade_timeout_msec: 1_000,
          reconnect_after_msec: [10],
          rejoin_after_msec: [10]
        ],
        Keyword.get(opts, :connection, [])
      )

    %__MODULE__{connection: Connection.new(channel_opts), port: port}
  end

  @doc "Start a server on its own, for a connection the test builds itself."
  @spec start_server(keyword()) :: non_neg_integer()
  def start_server(opts \\ []) do
    {:ok, _pid, port} =
      Utils.supervise_plug(WebSocketServer, Keyword.put_new(opts, :test_pid, self()))

    port
  end

  @doc "Start a server, connect to it, and wait until the upgrade is through."
  @spec connected(keyword()) :: t()
  def connected(opts \\ []) do
    opts |> start() |> connect() |> await(&(&1 == :connected))
  end

  @doc "Open the connection, asserting that the attempt got off the ground."
  @spec connect(t()) :: t()
  def connect(%__MODULE__{} = harness) do
    {:ok, connection} = Connection.connect(harness.connection)

    %{harness | connection: connection}
  end

  @doc """
  Join a topic and accept it, for tests that need a joined topic to start from.

  The server only answers what a test tells it to, so this plays the whole
  handshake: the join goes out, the reply comes back `ok`.
  """
  @spec join(t(), String.t(), term()) :: t()
  def join(%__MODULE__{} = harness, topic, params \\ %{}) do
    {:ok, connection} = Connection.join(harness.connection, topic, params)

    harness = %{harness | connection: connection}

    {message, harness} = await_received(harness, topic, "phx_join")

    harness
    |> server_reply(message, "ok")
    |> await(&match?({:joined, ^topic, _}, &1))
  end

  @doc """
  Feed the connection messages until one of its events matches, then stop.

  Fails the test if nothing matches in time.
  """
  @spec await(t(), (Connection.event() -> boolean()), timeout()) :: t()
  def await(%__MODULE__{} = harness, matcher, timeout \\ 2_000) do
    pump_until(
      harness,
      &Enum.any?(&1.events, matcher),
      fn harness ->
        """
        timed out waiting for a connection event to match.

        events so far: #{inspect(harness.events)}
        """
      end,
      deadline(timeout)
    )
  end

  @doc """
  Feed the connection everything that arrives until it has been quiet for a while.

  For when a test wants whatever happened rather than one particular event.
  """
  @spec drain(t(), timeout()) :: t()
  def drain(%__MODULE__{} = harness, quiet \\ 150) do
    receive do
      {:connection_test, info} ->
        harness |> put_info(info) |> drain(quiet)

      message ->
        harness |> handle(message) |> drain(quiet)
    after
      quiet -> harness
    end
  end

  @doc "Send a message to the connection, as NervesHub would."
  @spec server_push(t(), Message.t()) :: t()
  def server_push(%__MODULE__{} = harness, %Message{} = message) do
    server_send(harness, JSON.encode!(message))
  end

  @doc "Reply to a message the connection sent."
  @spec server_reply(t(), Message.t(), String.t(), term()) :: t()
  def server_reply(%__MODULE__{} = harness, %Message{} = to, status, response \\ %{}) do
    server_push(harness, %Message{
      topic: to.topic,
      event: "phx_reply",
      ref: to.ref,
      join_ref: to.join_ref,
      payload: %{"status" => status, "response" => response}
    })
  end

  @doc "Send a raw frame to the connection, for frames a serializer would not produce."
  @spec server_send(t(), WebSock.message()) :: t()
  def server_send(%__MODULE__{} = harness, frame) do
    harness = await_server(harness)

    send(harness.server, {:send_frame, frame})

    harness
  end

  @doc "Close the connection from the server's end."
  @spec server_close(t(), non_neg_integer()) :: t()
  def server_close(%__MODULE__{} = harness, code \\ 1000) do
    harness = await_server(harness)

    send(harness.server, {:close, code})

    harness
  end

  @doc """
  Wait until the server side has said which process it is.

  The server reports itself as it accepts the upgrade, which races with the
  upgrade response the connection is waiting for, so being connected is not on
  its own enough to know who to tell to send something.
  """
  @spec await_server(t(), timeout()) :: t()
  def await_server(harness, timeout \\ 2_000)

  def await_server(%__MODULE__{server: server} = harness, _timeout) when is_pid(server),
    do: harness

  def await_server(%__MODULE__{} = harness, timeout) do
    pump_until(
      harness,
      &is_pid(&1.server),
      fn _harness -> "timed out waiting for the server to report itself" end,
      deadline(timeout)
    )
  end

  @doc "Every message the server has received, decoded."
  @spec received(t()) :: [Message.t()]
  def received(%__MODULE__{frames: frames}) do
    for {:text, payload} <- frames, do: JSON.decode!(payload, :text)
  end

  @doc """
  Forget the events and frames recorded so far.

  `await/3` and `await_received/4` are satisfied by anything already in those
  lists, so a test that does the same thing twice - joins a topic again, sends
  a second heartbeat - has to forget the first round or it will match that and
  return without waiting for the second.
  """
  @spec forget(t()) :: t()
  def forget(%__MODULE__{} = harness), do: %{harness | events: [], frames: []}

  @doc "The last message the server received on a topic, waiting for it if needed."
  @spec await_received(t(), String.t(), String.t(), timeout()) :: {Message.t(), t()}
  def await_received(%__MODULE__{} = harness, topic, event, timeout \\ 2_000) do
    harness =
      pump_until(
        harness,
        &Enum.any?(received(&1), fn message ->
          message.topic == topic and message.event == event
        end),
        fn harness ->
          """
          timed out waiting for the server to receive #{topic}:#{event}.

          received: #{inspect(received(harness))}
          """
        end,
        deadline(timeout)
      )

    message =
      harness
      |> received()
      |> Enum.reverse()
      |> Enum.find(&(&1.topic == topic and &1.event == event))

    {message, harness}
  end

  ## Internals

  # One loop behind every wait: feed the connection what arrives, record what the
  # server tells us, and stop when `done?` says so or the deadline passes.
  defp pump_until(harness, done?, describe, deadline) do
    if done?.(harness) do
      harness
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0, do: flunk(describe.(harness))

      receive do
        {:connection_test, info} ->
          harness |> put_info(info) |> pump_until(done?, describe, deadline)

        message ->
          harness |> handle(message) |> pump_until(done?, describe, deadline)
      after
        remaining -> flunk(describe.(harness))
      end
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp handle(harness, message) do
    case Connection.handle_transport(harness.connection, message) do
      {:ok, connection, events} ->
        %{harness | connection: connection, events: harness.events ++ events}

      :unknown ->
        harness
    end
  end

  defp put_info(harness, {:server, pid}), do: %{harness | server: pid}

  defp put_info(harness, {:frame, opcode, payload}),
    do: %{harness | frames: harness.frames ++ [{opcode, payload}]}

  defp put_info(harness, _info), do: harness
end
