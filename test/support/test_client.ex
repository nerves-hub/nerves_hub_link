defmodule NervesHubLink.Support.TestClient do
  @moduledoc """
  Default NervesHubLink.Client implementation
  """

  use NervesHubLink.Client

  def reboot(), do: nil
end
