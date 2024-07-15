defmodule NervesHubLink.PubSub do
  @moduledoc """
  PubSub mechanism on top of basic Elixir Registry primitives.

  Wrapped up in a module for convenience and convenient correct use in
  libraries that extend NervesHubLink via this mechanism.
  """
  def child_spec(_) do
    Registry.child_spec(
      # Multiple registrations per key/topic
      keys: :duplicate,
      # Register by name
      name: __MODULE__,
      # Recommended from Elixir docs, shouldn't matter much
      # https://hexdocs.pm/elixir/1.17.2/Registry.html#module-using-as-a-pubsub
      partitions: System.schedulers_online()
    )
  end

  @doc """
  Publish to `NervesHubLink.Socket` to pass up to hub.
  """
  def publish_to_hub(topic, event, params) do
    publish("special:hub", {:to_hub, topic, event, params})
  end

  @doc """
  Subscribe to messages meant for the hub.
  Typically only used by `NervesHubLink.Socket`.
  """
  def subscribe_to_hub do
    subscribe("special:hub")
  end

  @doc """
  Publish to extensions or listeners that want messages from
  `NervesHubLink.Socket`. Typically only used by `NervesHubLink.Socket`.
  """
  def publish_channel_event(topic, event, params) do
    publish(topic, {:broadcast, :msg, topic, event, params})
  end

  @doc """
  Publish joins to extensions or listeners that want messages from
  `NervesHubLink.Socket`. Typically only used by `NervesHubLink.Socket`.
  """
  def publish_topic_join(topic, reply) do
    publish(topic, {:broadcast, :join, topic, reply})
  end

  @doc """
  Publish joins to extensions or listeners that want messages from
  `NervesHubLink.Socket`. Typically only used by `NervesHubLink.Socket`.
  """
  def publish_topic_close(topic, reason) do
    publish(topic, {:broadcast, :close, topic, reason})
  end

  @doc """
  Publish disconnect to extensions or listeners that want messages from
  `NervesHubLink.Socket`. Typically only used by `NervesHubLink.Socket`.
  """
  def publish_disconnect(topic, reason) do
    publish(topic, {:broadcast, :disconnect, topic, reason})
  end

  @doc """
  General PubSub subscribe for use in NervesHubLink. Generally used through
  `subscribe_to_others/0` and `subscribe_to_hub/0` but available if needed.
  """
  def subscribe(topic) do
    _ = Registry.register(__MODULE__, topic, [])
    :ok
  end

  @doc """
  General PubSub publish for use in NervesHubLink. Generally used through
  `publish_to_others/1` and `publish_to_hub/1` but available if needed.
  """
  def publish(topic, message) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, _} <- entries do
        send(pid, message)
      end
    end)
  end
end
