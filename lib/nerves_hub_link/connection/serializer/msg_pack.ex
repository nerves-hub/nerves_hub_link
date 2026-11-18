# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(Msgpax) do
  defmodule NervesHubLink.Connection.Serializer.MsgPack do
    @moduledoc """
    A Msgpack based serializer for Phoenix Channels messages.

    Msgpack encodes the same messages as the default JSON serializer in fewer
    bytes, which is worth having on metered or low bandwidth connections. To use
    it, add [`msgpax`](https://hex.pm/packages/msgpax) to your dependencies:

        def deps() do
          [
            {:msgpax, "~> 2.0"}
          ]
        end

    and select it in your config:

        config :nerves_hub_link,
          serializer: :msgpack

    Your NervesHub server must support Msgpack for this to work. If it doesn't,
    the device will fail to connect.

    Corresponds to `vsn=3.0.0`.
    """

    @behaviour NervesHubLink.Connection.Serializer

    alias NervesHubLink.Connection.Message
    alias NervesHubLink.Connection.Serializer
    alias NervesHubLink.Connection.Serializer.DecodeError
    alias NervesHubLink.Connection.Serializer.EncodeError

    @impl NervesHubLink.Connection.Serializer
    @spec encode!(Message.t()) :: {:binary, binary()}
    def encode!(%Message{} = message) do
      envelope = [message.join_ref, message.ref, message.topic, message.event, message.payload]

      case Msgpax.pack(envelope, iodata: false) do
        {:ok, packed} ->
          {:binary, packed}

        {:error, reason} ->
          raise EncodeError,
            message: "could not encode #{inspect(message.event)}: #{inspect(reason)}"
      end
    end

    @impl NervesHubLink.Connection.Serializer
    @spec decode!(binary(), NervesHubLink.Connection.Serializer.opcode()) :: Message.t()
    def decode!(payload, :binary) do
      case Msgpax.unpack(payload) do
        {:ok, [join_ref, ref, topic, event, payload | _later_additions]}
        when is_binary(topic) and is_binary(event) ->
          %Message{
            join_ref: Serializer.to_ref(join_ref),
            ref: Serializer.to_ref(ref),
            topic: topic,
            event: event,
            payload: payload
          }

        {:ok, [_join_ref, _ref, topic, event, _payload | _later_additions]} ->
          raise DecodeError,
            message:
              "expected a string topic and event, got: #{inspect(topic)} and #{inspect(event)}"

        {:ok, other} ->
          raise DecodeError,
            message: "expected an envelope of five or more elements, got: #{inspect(other)}"

        {:error, reason} ->
          raise DecodeError, message: "could not decode frame: #{inspect(reason)}"
      end
    end

    def decode!(_payload, opcode) do
      raise DecodeError, message: "expected a binary frame, got a #{inspect(opcode)} frame"
    end
  end
end
