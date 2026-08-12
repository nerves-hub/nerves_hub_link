# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.MsgPackSerializerTest do
  @moduledoc """
  The serializer sits on the wire for every message the device sends and
  receives, so what it puts on the wire is a contract with NervesHub, and
  anything it raises on the way past is a dropped connection.
  """

  use ExUnit.Case, async: true

  alias NervesHubLink.Extensions.Health.DeviceStatus
  alias NervesHubLink.MsgPackSerializer
  alias Slipstream.Message
  alias Slipstream.Serializer

  describe "encode!/2" do
    test "packs a message as the five element Phoenix envelope" do
      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: "device",
        event: "status_update",
        payload: %{"status" => "received"}
      }

      assert {:binary, packed} = MsgPackSerializer.encode!(message, [])

      assert Msgpax.unpack!(packed) == [
               "1",
               "2",
               "device",
               "status_update",
               %{"status" => "received"}
             ]
    end

    test "a message with no refs keeps them null" do
      message = %Message{topic: "device", event: "phx_join", payload: %{}}

      assert {:binary, packed} = MsgPackSerializer.encode!(message, [])
      assert [nil, nil, "device", "phx_join", %{}] = Msgpax.unpack!(packed)
    end

    test "atom keys and values are packed as strings" do
      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: "device",
        event: "fwup_progress",
        payload: %{stage: :updating, value: 50}
      }

      assert {:binary, packed} = MsgPackSerializer.encode!(message, [])
      assert [_, _, _, _, payload] = Msgpax.unpack!(packed)
      assert payload == %{"stage" => "updating", "value" => 50}
    end

    test "a health report round-trips, timestamp included" do
      status =
        DeviceStatus.new(
          timestamp: ~U[2026-08-12 01:02:03.456789Z],
          metrics: %{"cpu_usage_percent" => 12.5}
        )

      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: "extensions",
        event: "health:report",
        payload: %{"value" => status}
      }

      assert {:binary, packed} = MsgPackSerializer.encode!(message, [])
      assert [_, _, _, _, %{"value" => value}] = Msgpax.unpack!(packed)

      # Msgpack carries a timestamp as its own extension type rather than the
      # ISO 8601 string JSON sends, so the server has to understand it
      assert value["timestamp"] == ~U[2026-08-12 01:02:03.456789Z]
      assert value["metrics"] == %{"cpu_usage_percent" => 12.5}
    end

    test "a payload that can't be packed raises an EncodeError" do
      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: "console",
        event: "up",
        payload: {:binary, <<1, 2, 3>>}
      }

      assert_raise Serializer.EncodeError, fn ->
        MsgPackSerializer.encode!(message, [])
      end
    end
  end

  describe "decode!/2" do
    test "unpacks a message the server sent" do
      frame =
        pack([nil, "3", "device", "update", %{"firmware_url" => "http://example.test/a.fw"}])

      assert %Message{} = message = MsgPackSerializer.decode!(frame, opcode: :binary)

      assert message.join_ref == nil
      assert message.ref == "3"
      assert message.topic == "device"
      assert message.event == "update"
      assert message.payload == %{"firmware_url" => "http://example.test/a.fw"}
    end

    test "unpacks a reply" do
      frame =
        pack(["1", "2", "device", "phx_reply", %{"status" => "ok", "response" => %{}}])

      assert %Message{} = message = MsgPackSerializer.decode!(frame, opcode: :binary)

      assert message.event == "phx_reply"
      assert message.payload == %{"status" => "ok", "response" => %{}}
      assert message.ref == "2"
      assert message.join_ref == "1"
    end

    test "refs sent as integers become strings" do
      frame = pack([1, 2, "device", "ping", %{}])

      assert %Message{join_ref: "1", ref: "2"} = MsgPackSerializer.decode!(frame, opcode: :binary)
    end

    test "a message encoded by this serializer decodes back to itself" do
      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: "extensions",
        event: "health:check",
        payload: %{"a" => [1, 2, 3]}
      }

      {:binary, packed} = MsgPackSerializer.encode!(message, [])

      assert MsgPackSerializer.decode!(packed, opcode: :binary) == message
    end

    # Slipstream rescues DecodeError and leaves the connection up. Anything else
    # takes the connection process down with it.
    test "a malformed frame raises a DecodeError" do
      assert_raise Serializer.DecodeError, fn ->
        MsgPackSerializer.decode!(<<0x93, 1, 2, 3>>, opcode: :binary)
      end
    end

    test "a frame that isn't msgpack at all raises a DecodeError" do
      assert_raise Serializer.DecodeError, fn ->
        MsgPackSerializer.decode!("this is not msgpack", opcode: :binary)
      end
    end

    test "an envelope of the wrong shape raises a DecodeError" do
      assert_raise Serializer.DecodeError, fn ->
        MsgPackSerializer.decode!(pack(["only", "three", "elements"]), opcode: :binary)
      end
    end

    test "a text frame raises a DecodeError" do
      assert_raise Serializer.DecodeError, fn ->
        MsgPackSerializer.decode!(~s([null,"2","device","ping",{}]), opcode: :text)
      end
    end
  end

  defp pack(term), do: Msgpax.pack!(term, iodata: false)
end
