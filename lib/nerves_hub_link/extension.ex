defmodule NervesHubLink.Extension do
  @moduledoc """
  An Extension is a GenServer that can handle messages passed down from NervesHub
  and that can send messages up to NervesHub. It utilizes the regular NervesHubLink
  connection but are isolated to avoid crashing the main connection for things that
  are less important than the firmware update functionality.

  To configure an extension, simply add a child as if for a Supervisor, in config:alarm_handler

  ```
  config :nerves_hub_link,
    extensions: [
      NervesHubLink.Geo,
      NervesHubLink.Health,
      {MyExtension, interval: 500}
    ]
  ```

  """
  @callback events() :: [String.t()]

  @callback handle_message(event :: String.t(), params :: map(), state :: term()) ::
              {:noreply, new_state :: term()}
              | {:noreply, new_state :: term(),
                 timeout() | :hibernate | {:continue, continue_arg :: term()}}
              | {:stop, reason :: term(), new_state :: term()}

  @type t :: atom() | {atom(), term()} | Supervisor.child_spec()

  def forward(extension_events, event, params) do
    extension = Map.get(extension_events, event)

    if is_atom(extension) do
      pid = Process.whereis(extension)

      if pid do
        send(pid, {:event, event, params})
      end
    end
  end

  def extension_events_from_config(extensions) do
    extensions
    |> Enum.flat_map(fn child_spec ->
      # Unpack child structure
      module =
        case child_spec do
          module when is_atom(module) ->
            module

          child when is_tuple(child) ->
            elem(child, 0)

          %{start: {module, _, _}} ->
            module
        end

      module.events()
      |> Enum.map(fn event ->
        {event, module}
      end)
    end)
    |> Map.new()
  end

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour NervesHubLink.Extension

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def handle_info({:event, event, params}, state) do
        handle_message(event, params, state)
      end

      def push(event, params) do
        send(NervesHubLink.Socket, {:extension_msg, event, params})
      end
    end
  end
end
