defmodule NervesHubLink.HealthCheck do
  @moduledoc """

  Default config means not adding anything.

  Overriding config could be small:

  ```
  config :nerves_hub_link, :health,
      metadata: [organisation: "Biscuits Inc.", flavor: "chocolate"]
  ```

  Slightly more dynamic:

  ```
  config :nerves_hub_link, :health,
      metrics: [special_number: {System, :unique_integer, []}]
      
  ```

  Or completely custom:

  ```
  config :nerves_hub_link, :health, report: BiscuitBoard.HealthReport
  ```
  """
end
