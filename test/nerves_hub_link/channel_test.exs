# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ChannelTest do
  @moduledoc """
  Drives the channel against a real websocket server.

  The channel is a data structure, so the test process owns the connection
  itself and feeds the channel what arrives. Everything here therefore goes
  over a real socket: a real upgrade, real frames, a real close.
  """

  use ExUnit.Case, async: true

  alias Mint.WebSocket.UpgradeFailureError
  alias NervesHubLink.Channel
  alias NervesHubLink.Channel.Message
  alias NervesHubLink.Channel.Serializer.JSON
  alias NervesHubLink.Support.ChannelHarness, as: Harness

  @device_topic "device"

  describe "connecting" do
    test "a successful upgrade reports itself connected" do
      harness = Harness.connected()

      assert :connected in harness.events
      assert Channel.connected?(harness.channel)
    end

    test "the upgrade request asks for the path and protocol version in the URL" do
      port = Harness.start_server()

      channel =
        Channel.new(
          uri: URI.parse("ws://localhost:#{port}/socket/websocket?vsn=2.0.0"),
          serializer: JSON
        )

      assert {:ok, _channel} = Channel.connect(channel)
    end

    test "a connection that cannot be opened at all is an error, with nothing left open" do
      # Port 1 on loopback: nothing listens there, and binding it needs root.
      channel =
        Channel.new(uri: URI.parse("ws://localhost:1/socket/websocket"), serializer: JSON)

      assert {:error, %Mint.TransportError{}, channel} = Channel.connect(channel)
      refute Channel.connected?(channel)
      assert channel.conn == nil
    end

    test "a refused upgrade disconnects, carrying the status and headers" do
      harness =
        [server: [mode: :refuse, status: 403]]
        |> Harness.start()
        |> Harness.connect()
        |> Harness.await(&match?({:disconnected, _}, &1))

      assert [{:disconnected, {:upgrade_failure, %UpgradeFailureError{} = error}}] =
               Enum.filter(harness.events, &match?({:disconnected, _}, &1))

      assert error.status_code == 403
      refute Channel.connected?(harness.channel)
    end

    # The headers have to survive, because a redirect is followed by reading
    # `Location` out of them, and a bad device clock is recovered by reading
    # `Date`.
    test "a redirect disconnects with the location header intact" do
      harness =
        [server: [mode: :redirect, location: "https://elsewhere.test/socket/websocket"]]
        |> Harness.start()
        |> Harness.connect()
        |> Harness.await(&match?({:disconnected, _}, &1))

      assert [{:disconnected, {:upgrade_failure, error}}] =
               Enum.filter(harness.events, &match?({:disconnected, _}, &1))

      assert error.status_code == 302

      assert {_name, "https://elsewhere.test/socket/websocket"} =
               List.keyfind(error.headers, "location", 0)
    end

    test "a server that accepts the connection and never answers times out" do
      harness =
        [server: [mode: :silent], channel: [upgrade_timeout_msec: 200]]
        |> Harness.start()
        |> Harness.connect()
        |> Harness.await(&(&1 == {:disconnected, :upgrade_timeout}))

      refute Channel.connected?(harness.channel)
    end

    test "an upgrade timer from an earlier attempt is ignored" do
      harness = Harness.connected(channel: [upgrade_timeout_msec: 60_000])

      # The ref this names belongs to no attempt, so it must not be taken for
      # the current one.
      assert :unknown =
               Channel.handle_transport(harness.channel, {:channel_upgrade_timeout, make_ref()})

      assert Channel.connected?(harness.channel)
    end
  end

  describe "joining" do
    test "an accepted join reports the server's response" do
      harness = Harness.connected()

      assert {:ok, channel} = Channel.join(harness.channel, @device_topic, %{"id" => "abc"})
      harness = %{harness | channel: channel}

      {message, harness} = Harness.await_received(harness, @device_topic, "phx_join")

      assert message.payload == %{"id" => "abc"}
      # A join names itself as its own join, which is how its reply is known.
      assert message.ref == message.join_ref

      harness =
        harness
        |> Harness.server_reply(message, "ok", %{"extensions" => ["health"]})
        |> Harness.await(&match?({:joined, @device_topic, _}, &1))

      assert {:joined, @device_topic, %{"extensions" => ["health"]}} =
               Enum.find(harness.events, &match?({:joined, _, _}, &1))

      assert Channel.joined?(harness.channel, @device_topic)
    end

    test "a refused join reports why, and the topic is not joined" do
      harness = Harness.connected()

      assert {:ok, channel} = Channel.join(harness.channel, @device_topic)
      harness = %{harness | channel: channel}

      {message, harness} = Harness.await_received(harness, @device_topic, "phx_join")

      harness =
        harness
        |> Harness.server_reply(message, "error", %{"reason" => "unauthorized"})
        |> Harness.await(&match?({:join_failed, @device_topic, _}, &1))

      assert {:join_failed, @device_topic, {:failed_to_join, %{"reason" => "unauthorized"}}} =
               Enum.find(harness.events, &match?({:join_failed, _, _}, &1))

      refute Channel.joined?(harness.channel, @device_topic)
      assert Channel.join_status(harness.channel, @device_topic) == :closed
    end

    test "joining a topic that is already joined is left alone" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      before = harness.channel.ref

      assert {:ok, channel} = Channel.join(harness.channel, @device_topic)

      # No new ref was taken, so nothing was sent.
      assert channel.ref == before
    end

    test "joining before the connection is up is an error" do
      harness = Harness.start()

      assert {:error, :not_connected, _channel} = Channel.join(harness.channel, @device_topic)
    end

    test "a topic never joined has no join status" do
      harness = Harness.connected()

      assert Channel.join_status(harness.channel, "nope") == nil
      refute Channel.joined?(harness.channel, "nope")
    end

    test "rejoining repeats the parameters the topic was joined with" do
      harness =
        Harness.connected()
        |> Harness.join(@device_topic, %{"id" => "abc"})
        |> close_topic(@device_topic)

      assert {:ok, channel} = Channel.rejoin(harness.channel, @device_topic)

      # The stored params went out again, under a new ref.
      harness = Harness.drain(%{harness | channel: channel})

      joins = Enum.filter(Harness.received(harness), &(&1.event == "phx_join"))

      assert length(joins) == 2
      assert Enum.all?(joins, &(&1.payload == %{"id" => "abc"}))
      assert [first, second] = Enum.map(joins, & &1.ref)
      refute first == second
    end

    # Rejoining is what a topic-closed handler does, and it can race with a
    # join that already succeeded. Sending a second join for a topic the
    # server considers joined would be the server's problem to reject.
    test "rejoining a topic that is still joined does nothing" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      before = harness.channel.ref

      assert {:ok, channel} = Channel.rejoin(harness.channel, @device_topic)
      assert channel.ref == before
    end

    test "rejoining a topic that was never joined has no parameters to repeat" do
      harness = Harness.connected()

      assert {:error, :never_joined, _channel} = Channel.rejoin(harness.channel, "nope")
    end
  end

  describe "pushing" do
    test "a push is sent on the joined topic and answered by ref" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      assert {:ok, ref, channel} =
               Channel.push(harness.channel, @device_topic, "status_update", %{status: "received"})

      harness = %{harness | channel: channel}

      {message, harness} = Harness.await_received(harness, @device_topic, "status_update")

      assert message.ref == ref
      assert message.payload == %{"status" => "received"}

      harness =
        harness
        |> Harness.server_reply(message, "ok")
        |> Harness.await(&match?({:reply, ^ref, _}, &1))

      assert {:reply, ^ref, :ok} = Enum.find(harness.events, &match?({:reply, _, _}, &1))
    end

    test "a reply carrying a response keeps it" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      assert {:ok, ref, channel} = Channel.push(harness.channel, @device_topic, "check", %{})
      harness = %{harness | channel: channel}

      {message, harness} = Harness.await_received(harness, @device_topic, "check")

      harness =
        harness
        |> Harness.server_reply(message, "error", "detach")
        |> Harness.await(&match?({:reply, ^ref, _}, &1))

      assert {:reply, ^ref, {:error, "detach"}} =
               Enum.find(harness.events, &match?({:reply, _, _}, &1))
    end

    test "a binary payload goes out as a binary frame" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      assert {:ok, _ref, channel} =
               Channel.push(harness.channel, @device_topic, "up", {:binary, <<7, 8, 9>>})

      harness = Harness.drain(%{harness | channel: channel})

      assert Enum.any?(harness.frames, fn
               {:binary, payload} -> String.ends_with?(payload, <<7, 8, 9>>)
               _ -> false
             end)
    end

    test "pushing to a topic that is not joined is an error" do
      harness = Harness.connected()

      assert {:error, :not_joined, _channel} =
               Channel.push(harness.channel, @device_topic, "nope", %{})
    end

    test "pushing before the connection is up is an error" do
      harness = Harness.start()

      assert {:error, :not_connected, _channel} =
               Channel.push(harness.channel, @device_topic, "nope", %{})
    end

    test "a payload that cannot be encoded is reported without losing the connection" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      assert {:error, {:encode_failure, _}, channel} =
               Channel.push(harness.channel, @device_topic, "bad", %{pid: self()})

      assert Channel.connected?(channel)
    end

    test "refs increase, so a reply can only belong to one push" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      {refs, _channel} =
        Enum.map_reduce(1..3, harness.channel, fn _i, channel ->
          assert {:ok, ref, channel} = Channel.push(channel, @device_topic, "ping", %{})
          {ref, channel}
        end)

      assert refs == Enum.uniq(refs)

      assert Enum.map(refs, &String.to_integer/1) ==
               Enum.sort(Enum.map(refs, &String.to_integer/1))
    end
  end

  describe "receiving" do
    test "a message the server sends on its own is reported with its topic and event" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      harness =
        harness
        |> Harness.server_push(%Message{
          topic: @device_topic,
          event: "reboot",
          payload: %{},
          ref: nil
        })
        |> Harness.await(&match?({:message, @device_topic, "reboot", _}, &1))

      assert {:message, @device_topic, "reboot", %{}} =
               Enum.find(harness.events, &match?({:message, _, _, _}, &1))
    end

    test "a topic the server closes with an error is reported as closed" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      join_ref = harness.channel.joins[@device_topic].ref

      harness =
        harness
        |> Harness.server_push(%Message{
          topic: @device_topic,
          event: "phx_error",
          payload: %{},
          ref: join_ref,
          join_ref: join_ref
        })
        |> Harness.await(&match?({:topic_closed, @device_topic, _}, &1))

      refute Channel.joined?(harness.channel, @device_topic)
      # The connection itself is still up; only the topic went.
      assert Channel.connected?(harness.channel)
    end

    test "a topic the server closes normally is reported as left" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      join_ref = harness.channel.joins[@device_topic].ref

      harness =
        harness
        |> Harness.server_push(%Message{
          topic: @device_topic,
          event: "phx_close",
          payload: %{},
          ref: join_ref,
          join_ref: join_ref
        })
        |> Harness.await(&(&1 == {:topic_left, @device_topic}))

      refute Channel.joined?(harness.channel, @device_topic)
      assert Channel.connected?(harness.channel)
    end

    test "a frame that cannot be decoded is dropped, not fatal" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      harness =
        harness
        |> Harness.server_send({:text, "this is not an envelope"})
        |> Harness.server_push(%Message{
          topic: @device_topic,
          event: "identify",
          payload: %{},
          ref: nil
        })
        |> Harness.await(&match?({:message, @device_topic, "identify", _}, &1))

      # The message after the bad frame still arrived, so the connection
      # survived the bad one.
      assert Channel.connected?(harness.channel)
      refute Enum.any?(harness.events, &match?({:disconnected, _}, &1))
    end

    test "a close frame from the server disconnects" do
      harness = Harness.connected()

      harness =
        harness
        |> Harness.server_close()
        |> Harness.await(&(&1 == {:disconnected, :closed_by_remote}))

      refute Channel.connected?(harness.channel)
    end
  end

  describe "heartbeats" do
    test "a heartbeat is sent on its own topic and acknowledged by ref" do
      harness = Harness.connected()

      assert {:ok, channel} = Channel.send_heartbeat(harness.channel)
      assert is_binary(channel.heartbeat_ref)

      harness = %{harness | channel: channel}

      {message, harness} = Harness.await_received(harness, "phoenix", "heartbeat")

      assert message.payload == %{}

      harness =
        harness
        |> Harness.server_reply(message, "ok")
        |> Harness.drain()

      # The ack clears the outstanding heartbeat, and is not an event the
      # owner has to care about.
      assert harness.channel.heartbeat_ref == nil
      refute Enum.any?(harness.events, &match?({:reply, _, _}, &1))
    end

    test "an unacknowledged heartbeat closes the connection on the next one" do
      harness = Harness.connected()

      assert {:ok, channel} = Channel.send_heartbeat(harness.channel)

      # The server was never told to reply, so the second heartbeat finds the
      # first still outstanding.
      assert {:error, :heartbeat_timeout, channel} = Channel.send_heartbeat(channel)

      refute Channel.connected?(channel)
    end

    test "heartbeats can be sent one after another once acknowledged" do
      harness = Harness.connected()

      assert {:ok, channel} = Channel.send_heartbeat(harness.channel)
      harness = %{harness | channel: channel}

      {first, harness} = Harness.await_received(harness, "phoenix", "heartbeat")
      harness = harness |> Harness.server_reply(first, "ok") |> Harness.drain()

      assert {:ok, channel} = Channel.send_heartbeat(harness.channel)
      assert channel.heartbeat_ref != first.ref
    end

    test "a heartbeat before the connection is up is an error" do
      harness = Harness.start()

      assert {:error, :not_connected, _channel} = Channel.send_heartbeat(harness.channel)
    end
  end

  describe "control frames" do
    test "a ping is answered with a pong" do
      harness = Harness.connected()

      harness =
        harness
        |> Harness.server_send({:ping, "are you there"})
        |> Harness.drain()

      assert {:pong, "are you there"} in harness.frames
      assert Channel.connected?(harness.channel)
    end
  end

  describe "closing" do
    test "closing reports nothing, because the caller asked for it" do
      harness = Harness.connected() |> Harness.join(@device_topic)

      channel = Channel.close(harness.channel)

      refute Channel.connected?(channel)
      refute Channel.joined?(channel, @device_topic)
      assert channel.conn == nil
    end

    test "a closed channel ignores messages rather than claiming them" do
      harness = Harness.connected()

      channel = Channel.close(harness.channel)

      assert :unknown = Channel.handle_transport(channel, {:tcp, :fake_socket, "nonsense"})
    end

    test "a message that belongs to nothing here is left for the owner" do
      harness = Harness.connected()

      assert :unknown = Channel.handle_transport(harness.channel, :some_other_message)
    end
  end

  # The response to the upgrade can be split across TCP segments however the
  # network likes. Taking the status and headers only when they arrive together
  # leaves the device stuck, so each is kept until both are in.
  describe "an upgrade response split across packets" do
    test "the upgrade completes when the status and headers arrive separately" do
      port = raw_upgrade_server(split: true, then_send: nil)

      harness =
        [channel: [uri: URI.parse("ws://localhost:#{port}/socket/websocket?vsn=2.0.0")]]
        |> start_against_raw_server()
        |> Harness.await(&(&1 == :connected))

      assert Channel.connected?(harness.channel)
    end

    test "a frame in the same packet as the end of the response is still decoded" do
      message = %Message{topic: @device_topic, event: "identify", payload: %{}, ref: nil}
      {:text, encoded} = JSON.encode!(message)

      port = raw_upgrade_server(split: true, then_send: text_frame(encoded))

      harness =
        [channel: [uri: URI.parse("ws://localhost:#{port}/socket/websocket?vsn=2.0.0")]]
        |> start_against_raw_server()
        |> Harness.await(&match?({:message, @device_topic, "identify", _}, &1))

      assert :connected in harness.events
    end
  end

  describe "backoff" do
    test "each reconnect waits one step further along the list" do
      channel = Channel.new(uri: uri(), serializer: JSON, reconnect_after_msec: [1, 2, 3])

      {delays, channel} =
        Enum.map_reduce(1..5, channel, fn _i, channel ->
          {delay, channel} = Channel.reconnect_delay(channel)
          {delay, channel}
        end)

      # Past the end of the list the longest wait repeats.
      assert delays == [1, 2, 3, 3, 3]
      assert channel.reconnect_count == 5
    end

    test "connecting successfully starts the reconnect backoff over" do
      harness = Harness.connected(channel: [reconnect_after_msec: [1, 2, 3]])

      assert harness.channel.reconnect_count == 0

      {_delay, channel} = Channel.reconnect_delay(harness.channel)
      assert channel.reconnect_count == 1
    end

    test "each rejoin of a topic waits one step further along its own list" do
      harness = Harness.connected(channel: [rejoin_after_msec: [5, 10]])
      harness = Harness.join(harness, @device_topic)

      {first, channel} = Channel.rejoin_delay(harness.channel, @device_topic)
      {second, channel} = Channel.rejoin_delay(channel, @device_topic)
      {third, _channel} = Channel.rejoin_delay(channel, @device_topic)

      assert [first, second, third] == [5, 10, 10]
    end

    test "topics back off independently of each other" do
      harness = Harness.connected(channel: [rejoin_after_msec: [5, 10]])
      harness = Harness.join(harness, @device_topic)
      harness = Harness.join(harness, "console")

      {_first, channel} = Channel.rejoin_delay(harness.channel, @device_topic)
      {console, _channel} = Channel.rejoin_delay(channel, "console")

      assert console == 5
    end

    test "joining successfully starts that topic's backoff over" do
      harness = Harness.connected(channel: [rejoin_after_msec: [5, 10]])
      harness = harness |> Harness.join(@device_topic) |> close_topic(@device_topic)

      {_delay, channel} = Channel.rejoin_delay(harness.channel, @device_topic)
      assert channel.joins[@device_topic].rejoin_count == 1

      # Rejoining and being accepted puts it back to the shortest wait.
      assert {:ok, channel} = Channel.rejoin(channel, @device_topic)
      harness = Harness.forget(%{harness | channel: channel})

      {message, harness} = Harness.await_received(harness, @device_topic, "phx_join")

      harness =
        harness
        |> Harness.server_reply(message, "ok")
        |> Harness.await(&match?({:joined, @device_topic, _}, &1))

      assert harness.channel.joins[@device_topic].rejoin_count == 0
    end
  end

  ## Helpers

  defp uri(), do: URI.parse("ws://localhost:4000/socket/websocket?vsn=2.0.0")

  # Has the server close a joined topic, which is the state a rejoin starts
  # from. The connection itself stays up.
  defp close_topic(harness, topic) do
    join_ref = harness.channel.joins[topic].ref

    harness
    |> Harness.server_push(%Message{
      topic: topic,
      event: "phx_error",
      payload: %{},
      ref: join_ref,
      join_ref: join_ref
    })
    |> Harness.await(&match?({:topic_closed, ^topic, _}, &1))
  end

  defp start_against_raw_server(opts) do
    opts |> Harness.start() |> Harness.connect()
  end

  # A websocket server built by hand, so the upgrade response can be written
  # in whatever pieces a test wants. Bandit sends its own in one go.
  defp raw_upgrade_server(opts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: 0])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 5_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)

      accept = websocket_accept(request)

      status = "HTTP/1.1 101 Switching Protocols\r\n"

      headers =
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"

      trailing = opts[:then_send] || ""

      if opts[:split] do
        :ok = :gen_tcp.send(socket, status)
        # Long enough that Mint certainly delivers the status on its own.
        Process.sleep(50)
        :ok = :gen_tcp.send(socket, headers <> trailing)
      else
        :ok = :gen_tcp.send(socket, status <> headers <> trailing)
      end

      Process.sleep(:infinity)
    end)

    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  @websocket_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defp websocket_accept(request) do
    [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)

    :crypto.hash(:sha, key <> @websocket_guid) |> Base.encode64()
  end

  # An unmasked text frame, which is what a server sends.
  defp text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload)::8, payload::binary>>
  end
end
