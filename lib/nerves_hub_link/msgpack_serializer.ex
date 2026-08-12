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

    @spec encode!(Message.t(), Keyword.t()) :: {:binary, binary()}
    def encode!(%Message{} = msg, _opts) do
      data = [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload]

      {:ok, envelope} = Msgpax.pack(data, iodata: false)

      {:binary, envelope}
    end

    @spec decode!(binary(), Keyword.t()) :: Message.t()
    def decode!(binary, opts) do
      case Keyword.fetch!(opts, :opcode) do
        :binary ->
          {:ok, envelope} = Msgpax.unpack(binary)

          [join_ref, ref, topic, event, payload] = envelope

          case event do
            "phx_reply" ->
              %Message{
                topic: topic,
                event: "phx_reply",
                payload: payload,
                ref: to_ref_string(ref),
                join_ref: to_ref_string(join_ref)
              }

            _ ->
              %Message{
                join_ref: to_ref_string(join_ref),
                ref: to_ref_string(ref),
                topic: topic,
                event: event,
                payload: payload
              }
          end
      end
    end

    defp to_ref_string(nil), do: nil
    defp to_ref_string(ref), do: to_string(ref)
  end
end
