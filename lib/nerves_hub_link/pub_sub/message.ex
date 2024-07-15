defmodule NervesHubLink.PubSub.Message do
  defstruct type: nil, topic: nil, event: nil, params: nil, reply: nil, reason: nil

  alias __MODULE__, as: M

  @type t :: %M{
          type: :msg | :join | :close | :disconnect,
          topic: String.t(),
          event: String.t() | nil,
          params: map() | nil,
          reply: map() | nil,
          reason: term() | nil
        }

  def msg(topic, event, params)
      when is_binary(topic) and
             is_binary(event) and
             is_map(params) do
    %M{type: :msg, topic: topic, event: event, params: params}
  end

  def join(topic, reply)
      when is_binary(topic) and
             is_map(reply) do
    %M{type: :join, topic: topic, reply: reply}
  end

  def close(topic, reason)
      when is_binary(topic) do
    %{type: :close, topic: topic, reason: reason}
  end

  def disconnect(topic, reason)
      when is_binary(topic) do
    %{type: :disconnect, topic: topic, reason: reason}
  end
end
