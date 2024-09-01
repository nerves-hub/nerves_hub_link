defmodule NervesHubLink.Features.Geo.Resolver do
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
