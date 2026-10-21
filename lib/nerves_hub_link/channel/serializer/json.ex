# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Channel.Serializer.JSON do
  @moduledoc """
  The default serializer, matching Phoenix's `Phoenix.Socket.V2.JSONSerializer`.

  Messages are JSON arrays of the five envelope fields, sent in text frames:

      [join_ref, ref, topic, event, payload]

  A payload that is already binary is sent in a binary frame instead, with the
  envelope packed into a header ahead of it, because JSON cannot carry bytes
  without growing them by a third. The server uses the same two forms, so
  either may arrive.

  Corresponds to `vsn=2.0.0`.
  """

  @behaviour NervesHubLink.Channel.Serializer

  alias NervesHubLink.Channel.Message
  alias NervesHubLink.Channel.Serializer.DecodeError
  alias NervesHubLink.Channel.Serializer.EncodeError

  # The first byte of a binary frame says which kind of message it is. The
  # device only ever sends pushes; the other two are what the server sends.
  @push 0
  @reply 1
  @broadcast 2

  # Each envelope field's length is one byte of the header.
  @max_field_size 255

  @impl NervesHubLink.Channel.Serializer
  @spec encode!(Message.t()) :: NervesHubLink.Channel.Serializer.frame()
  def encode!(%Message{payload: {:binary, data}} = message) do
    join_ref = to_string(message.join_ref)
    ref = to_string(message.ref)

    {:binary,
     <<
       @push::8,
       field_size!(join_ref, :join_ref)::8,
       field_size!(ref, :ref)::8,
       field_size!(message.topic, :topic)::8,
       field_size!(message.event, :event)::8,
       join_ref::binary,
       ref::binary,
       message.topic::binary,
       message.event::binary,
       data::binary
     >>}
  end

  def encode!(%Message{} = message) do
    envelope = [message.join_ref, message.ref, message.topic, message.event, message.payload]

    case Jason.encode(envelope) do
      {:ok, encoded} ->
        {:text, encoded}

      {:error, reason} ->
        raise EncodeError,
          message: "could not encode #{inspect(message.event)}: #{inspect(reason)}"
    end
  end

  @impl NervesHubLink.Channel.Serializer
  @spec decode!(binary(), NervesHubLink.Channel.Serializer.opcode()) :: Message.t()
  def decode!(payload, :text) do
    case Jason.decode(payload) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        %Message{
          join_ref: join_ref,
          ref: ref,
          topic: topic,
          event: event,
          payload: payload
        }

      {:ok, other} ->
        raise DecodeError,
          message: "expected a five element envelope, got: #{inspect(other)}"

      {:error, reason} ->
        raise DecodeError, message: "could not decode frame: #{inspect(reason)}"
    end
  end

  def decode!(payload, :binary), do: decode_binary!(payload)

  # A push and a broadcast differ only in whether they name the join they
  # belong to. Neither carries a `ref`, because the server did not ask for a
  # reply to it.
  defp decode_binary!(<<
         @push::8,
         join_ref_size::8,
         topic_size::8,
         event_size::8,
         join_ref::binary-size(join_ref_size),
         topic::binary-size(topic_size),
         event::binary-size(event_size),
         data::binary
       >>) do
    %Message{
      topic: topic,
      event: event,
      payload: {:binary, data},
      ref: nil,
      join_ref: join_ref
    }
  end

  defp decode_binary!(<<
         @reply::8,
         join_ref_size::8,
         ref_size::8,
         topic_size::8,
         status_size::8,
         join_ref::binary-size(join_ref_size),
         ref::binary-size(ref_size),
         topic::binary-size(topic_size),
         status::binary-size(status_size),
         data::binary
       >>) do
    %Message{
      topic: topic,
      event: "phx_reply",
      payload: %{"status" => status, "response" => {:binary, data}},
      ref: ref,
      join_ref: join_ref
    }
  end

  defp decode_binary!(<<
         @broadcast::8,
         topic_size::8,
         event_size::8,
         topic::binary-size(topic_size),
         event::binary-size(event_size),
         data::binary
       >>) do
    %Message{
      topic: topic,
      event: event,
      payload: {:binary, data},
      ref: nil,
      join_ref: nil
    }
  end

  defp decode_binary!(payload) do
    raise DecodeError,
      message: "could not decode binary frame of #{byte_size(payload)} byte(s)"
  end

  defp field_size!(field, name) do
    case byte_size(field) do
      size when size <= @max_field_size ->
        size

      oversized ->
        raise EncodeError,
          message:
            "#{name} must be at most #{@max_field_size} bytes to be sent in a binary frame," <>
              " but is #{oversized} bytes: #{inspect(field)}"
    end
  end
end
