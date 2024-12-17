defmodule NervesHubLink.Extensions.Geo.Resolver do
  @moduledoc """
  Geo extension behaviour for writing custom resolvers.

  For example to support your GPS or LTE modem's means of geo-location.

  Default implementation is `NervesHubLink.Extensions.Geo.DefaultResolver`.
  """

  @typedoc "Location information from a successful location resolution"
  @type location_information() :: %{
          :latitude => float(),
          :longitude => float(),
          :source => String.t(),
          optional(:accuracy) => pos_integer()
        }

  @typedoc "Formatted error response from a failed location resolution"
  @type error_information() :: %{error_code: String.t(), error_description: String.t()}

  @typedoc "Supported responses from `resolve_location/0`"
  @type location_responses() ::
          {:ok, location_information()}
          | {:error, error_information()}

  @callback resolve_location() :: location_responses()
end
