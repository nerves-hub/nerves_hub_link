defmodule NervesHubLink.Extensions.Connection do
  use NervesHubLink.Extensions, name: "connection", version: "0.0.1"

  alias NervesHubLink.Extensions.Connection.DefaultResolver

  require Logger

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl NervesHubLink.Extensions
  def handle_event(event, _, state) do
    Logger.info("Connection extension received unexpected event: #{event}")
    {:noreply, state}
  end

  defp resolve_current_connection_type do
    resolver = Application.get_env(:nerves_hub_link, :connection, [])[:resolver] || DefaultResolver
    if function_exported?(resolver, :resolve_connection_type, 0), do: resolver, else: DefaultResolver
  end
end
