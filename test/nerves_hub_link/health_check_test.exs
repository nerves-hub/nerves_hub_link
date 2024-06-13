defmodule NervesHubLink.HealthCheckTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.ClientMock
  alias NervesHubLink.Message.DeviceStatus

  setup context do
    Mox.verify_on_exit!(context)
  end

  @mock_ts DateTime.utc_now()
  @mock_status %{
    timestamp: @mock_ts,
    metadata: %{version: "1.5"},
    metrics: %{temperature: 5.0},
    alarms: %{},
    peripherals: %{}
  }

  test "default health check without hardware" do
    empty_map = %{}
    Mox.expect(ClientMock, :check_health, fn -> DeviceStatus.new(@mock_status) end)

    assert %{
             timestamp: @mock_ts,
             metadata: %{version: "1.5"},
             metrics: %{temperature: 5.0},
             peripherals: ^empty_map
           } =
             NervesHubLink.check_health()
  end
end
