defmodule NervesHubLink.Extensions.Geo.DefaultResolver do
  alias NervesHubLink.Extensions.Geo.Resolver
  @behaviour Resolver

  @impl Resolver
  def resolve_location() do
    case Whenwhere.asks() do
      {:ok, resp} ->
        payload = %{
          source: "geoip",
          latitude: resp[:latitude],
          longitude: resp[:longitude]
        }

        {:ok, payload}

      {:error, error} ->
        {:error, "HTTP_ERROR", inspect(error)}
    end
  end
end
