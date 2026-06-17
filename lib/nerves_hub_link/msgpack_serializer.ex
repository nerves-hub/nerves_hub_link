defmodule NervesHubLink.MsgPackSerializer do
  @behaviour Slipstream.Serializer

  alias Slipstream.Message

  def encode!(%Message{} = msg, _opts) do
    data = [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload]

    {:ok, envelope} = Msgpax.pack(data, iodata: false)

    {:binary, envelope}
  end

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
