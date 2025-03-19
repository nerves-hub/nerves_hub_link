# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Geo.DefaultResolver do
  @moduledoc """
  Default `Resolver` implementation.

  Uses the Nerves project's `whenwhere` service and library to perform a rough
  GeoIP-lookup. Please use within reason. The Nerves team provides no
  guarantees for this service's availability or continued operation. With some
  luck it should be up, reliable and useful.
  """

  @behaviour NervesHubLink.Extensions.Geo.Resolver

  alias NervesHubLink.Extensions.Geo.Resolver

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
