defmodule NervesHubLink.Support.Utils do
  def unique_port_number() do
    System.unique_integer([:positive, :monotonic]) + 6000
  end
end
