defmodule NervesHubLink.ExtensionTest do
  use ExUnit.Case

  alias NervesHubLink.Extension

  defmodule MyExtension do
    use NervesHubLink.Extension

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl NervesHubLink.Extension
    def events do
      ["my-event"]
    end

    @impl NervesHubLink.Extension
    def handle_message("my-event", %{sender: pid}, state) do
      send(pid, :got_message)
      push("my-push", %{data: 1})
      {:noreply, state}
    end
  end

  test "try extension receive and send" do
    {:ok, _pid} = MyExtension.start_link([])
    extensions = [MyExtension]
    events = Extension.extension_events_from_config(extensions)
    Extension.forward(events, "my-event", %{sender: self()})
    assert_receive :got_message
  end
end
