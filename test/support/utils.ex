defmodule NervesHubLink.Support.Utils do
  @moduledoc false

  @spec unique_port_number() :: integer()
  def unique_port_number() do
    System.unique_integer([:positive, :monotonic]) + 6000
  end
end
