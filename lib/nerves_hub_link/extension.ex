defmodule NervesHubLink.Extension do
  @callback name :: module() | String.t()
  @callback settings :: map()
  @callback handle_message(String.t(), map()) ::
              :ok | {:push, String.t(), Slipstream.json_serializable() | {:binary, binary()}}
end
