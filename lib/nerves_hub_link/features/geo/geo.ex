defmodule NervesHubLink.Features.Geo do
  use NervesHubLink.Features, name: "geo", version: "0.0.1"

  alias NervesHubLink.Features.Geo.DefaultResolver

  require Logger

  @impl GenServer
  def init(_opts) do
    {:ok, %{}, {:continue, :location_update}}
  end

  @impl GenServer
  def handle_continue(:location_update, state) do
    _ = location_update()
    {:noreply, state}
  end

  @impl NervesHubLink.Features
  def handle_event("location:update", _msg, state) do
    _ = location_update()
    {:noreply, state}
  end

  defp location_update() do
    push("location:update", resolve_location())
  end

  defp resolve_location() do
    resolver = resolver()

    case resolver.resolve_location() do
      {:ok, result} ->
        Logger.debug(
          "[#{inspect(__MODULE__)}] Location resolution completed successfully using #{inspect(resolver)}"
        )

        result

      {:error, code, description} ->
        Logger.debug(
          "[#{inspect(__MODULE__)}] Error resolving location using #{inspect(resolver)} : (#{code}) #{description}"
        )

        %{error_code: code, error_description: description}
    end
  end

  defp resolver() do
    resolver = Application.get_env(:nerves_hub_link, :geo)[:resolver] || DefaultResolver
    if function_exported?(resolver, :resolve_location, 0), do: resolver, else: DefaultResolver
  end
end
