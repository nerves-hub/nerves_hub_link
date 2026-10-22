# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Connection.Serializer.JSONTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Connection.Message
  alias NervesHubLink.Connection.Serializer.DecodeError
  alias NervesHubLink.Connection.Serializer.EncodeError
  alias NervesHubLink.Connection.Serializer.JSON

  describe "encode!/1" do
    test "a message becomes the five element envelope, in a text frame" do
      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: "device",
        event: "status_update",
        payload: %{status: "received"}
      }

      assert {:text, encoded} = JSON.encode!(message)

      assert Jason.decode!(encoded) == [
               "1",
               "2",
               "device",
               "status_update",
               %{"status" => "received"}
             ]
    end

    test "refs that have not been assigned are sent as null" do
      message = %Message{topic: "phoenix", event: "heartbeat", payload: %{}, ref: "7"}

      assert {:text, encoded} = JSON.encode!(message)
      assert Jason.decode!(encoded) == [nil, "7", "phoenix", "heartbeat", %{}]
    end

    test "a binary payload becomes a binary frame with the envelope as a header" do
      message = %Message{
        join_ref: "1",
        ref: "22",
        topic: "console",
        event: "up",
        payload: {:binary, <<0, 1, 2>>}
      }

      assert {:binary, encoded} = JSON.encode!(message)

      assert <<0::8, 1::8, 2::8, 7::8, 2::8, rest::binary>> = encoded
      assert rest == "1" <> "22" <> "console" <> "up" <> <<0, 1, 2>>
    end

    test "a payload that cannot be represented as JSON is an encode error" do
      message = %Message{topic: "device", event: "x", payload: %{pid: self()}}

      assert_raise EncodeError, fn -> JSON.encode!(message) end
    end

    test "an envelope field too long for a binary frame's header is an encode error" do
      message = %Message{
        join_ref: "1",
        ref: "2",
        topic: String.duplicate("t", 256),
        event: "up",
        payload: {:binary, ""}
      }

      assert_raise EncodeError, ~r/at most 255 bytes/, fn -> JSON.encode!(message) end
    end
  end

  describe "decode!/2" do
    test "a text envelope becomes a message" do
      payload = Jason.encode!(["1", "2", "device", "update", %{"firmware_url" => "http://x"}])

      assert %Message{} = message = JSON.decode!(payload, :text)

      assert message.join_ref == "1"
      assert message.ref == "2"
      assert message.topic == "device"
      assert message.event == "update"
      assert message.payload == %{"firmware_url" => "http://x"}
    end

    test "a message the server sent on its own has no ref" do
      payload = Jason.encode!([nil, nil, "device", "reboot", %{}])

      assert %Message{ref: nil, join_ref: nil, event: "reboot"} = JSON.decode!(payload, :text)
    end

    test "a binary push becomes a message with a binary payload" do
      frame = <<0::8, 1::8, 7::8, 2::8, "1", "console", "up", 9, 9>>

      assert %Message{} = message = JSON.decode!(frame, :binary)

      assert message.join_ref == "1"
      assert message.ref == nil
      assert message.topic == "console"
      assert message.event == "up"
      assert message.payload == {:binary, <<9, 9>>}
    end

    test "a binary reply becomes a phx_reply" do
      frame = <<1::8, 1::8, 2::8, 6::8, 2::8, "1", "12", "device", "ok", 5>>

      assert %Message{} = message = JSON.decode!(frame, :binary)

      assert message.event == "phx_reply"
      assert message.ref == "12"
      assert message.topic == "device"
      assert message.payload == %{"status" => "ok", "response" => {:binary, <<5>>}}
    end

    test "a binary broadcast becomes a message belonging to no join" do
      frame = <<2::8, 6::8, 4::8, "device", "ping", 1>>

      assert %Message{} = message = JSON.decode!(frame, :binary)

      assert message.join_ref == nil
      assert message.ref == nil
      assert message.topic == "device"
      assert message.event == "ping"
      assert message.payload == {:binary, <<1>>}
    end

    test "text that is not JSON is a decode error" do
      assert_raise DecodeError, ~r/could not decode/, fn ->
        JSON.decode!("{not json", :text)
      end
    end

    test "JSON that is not an envelope at all is a decode error" do
      assert_raise DecodeError, ~r/five or more elements/, fn ->
        JSON.decode!(Jason.encode!(%{"topic" => "device"}), :text)
      end

      assert_raise DecodeError, ~r/five or more elements/, fn ->
        JSON.decode!(Jason.encode!(["1", "2"]), :text)
      end
    end

    # A later protocol version adding a field should leave the device reading
    # its messages, not refusing every one of them.
    test "an envelope with more than five elements is still read" do
      payload = Jason.encode!(["1", "2", "device", "update", %{"a" => 1}, "later", "additions"])

      assert %Message{} = message = JSON.decode!(payload, :text)

      assert message.topic == "device"
      assert message.event == "update"
      assert message.payload == %{"a" => 1}
    end

    # The connection stores refs as strings and matches a reply to what it
    # answers by comparing them, so a numeric ref would match nothing and the
    # reply would be lost without a word.
    test "a numeric ref becomes the string the connection stores" do
      payload = Jason.encode!([3, 7, "phoenix", "phx_reply", %{}])

      assert %Message{join_ref: "3", ref: "7"} = JSON.decode!(payload, :text)
    end

    # These travel as far as being logged, and that log says them with string
    # interpolation, which not every type JSON allows survives.
    test "a topic or event that is not a string is a decode error" do
      assert_raise DecodeError, ~r/string topic and event/, fn ->
        JSON.decode!(Jason.encode!(["1", nil, %{"not" => "a topic"}, "event", %{}]), :text)
      end

      assert_raise DecodeError, ~r/string topic and event/, fn ->
        JSON.decode!(Jason.encode!(["1", nil, "device", %{"not" => "an event"}, %{}]), :text)
      end
    end

    test "a ref that is neither a string nor a number is a decode error" do
      assert_raise DecodeError, ~r/string, a number or null/, fn ->
        JSON.decode!(Jason.encode!(["1", %{}, "device", "event", %{}]), :text)
      end
    end

    test "a binary frame in none of the three shapes is a decode error" do
      assert_raise DecodeError, ~r/could not decode binary frame/, fn ->
        JSON.decode!(<<9, 9, 9>>, :binary)
      end
    end
  end

  describe "round trip" do
    test "what this serializer encodes, it can decode" do
      # The server's push shape rather than the device's: a device never
      # receives its own frames, so this goes through the matching pair.
      message = %Message{
        join_ref: "3",
        ref: nil,
        topic: "extensions",
        event: "health:check",
        payload: %{"deep" => %{"nested" => [1, 2, 3]}}
      }

      assert {:text, encoded} = JSON.encode!(message)
      assert JSON.decode!(encoded, :text) == message
    end
  end
end
