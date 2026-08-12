# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(Msgpax) do
  defmodule NervesHubLink.MsgPackSerializer do
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
    """

    @behaviour Slipstream.Serializer

    alias Slipstream.Message
    alias Slipstream.Serializer

    @impl Slipstream.Serializer
    @spec encode!(Message.t(), Keyword.t()) :: {:binary, binary()}
    def encode!(%Message{} = message, _opts) do
      envelope = [message.join_ref, message.ref, message.topic, message.event, message.payload]

      case Msgpax.pack(envelope, iodata: false) do
        {:ok, packed} ->
          {:binary, packed}

        {:error, reason} ->
          raise Serializer.EncodeError,
            message: "could not encode #{inspect(message.event)}: #{inspect(reason)}"
      end
    end

    @impl Slipstream.Serializer
    @spec decode!(binary(), Keyword.t()) :: Message.t()
    def decode!(binary, opts) do
      # Anything the server sends could be malformed, and a serializer that
      # raises something other than a DecodeError takes the connection down with
      # it - Slipstream only rescues DecodeError.
      with :binary <- Keyword.fetch!(opts, :opcode),
           {:ok, [join_ref, ref, topic, event, payload]} <- Msgpax.unpack(binary) do
        %Message{
          join_ref: to_ref_string(join_ref),
          ref: to_ref_string(ref),
          topic: topic,
          event: event,
          payload: payload
        }
      else
        opcode when is_atom(opcode) ->
          raise Serializer.DecodeError,
            message: "expected a binary frame, got a #{inspect(opcode)} frame"

        {:ok, other} ->
          raise Serializer.DecodeError,
            message: "expected a five element envelope, got: #{inspect(other)}"

        {:error, reason} ->
          raise Serializer.DecodeError, message: "could not decode frame: #{inspect(reason)}"
      end
    end

    defp to_ref_string(nil), do: nil
    defp to_ref_string(ref), do: to_string(ref)
  end
end
