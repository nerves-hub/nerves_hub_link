defmodule NervesHubLink.Downloader.TimeoutCalculationTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.Downloader.TimeoutCalculation

  test "calculate_worst_case_timeout" do
    # 20 mb @ 30 b/sec is about 1.5 hours
    assert TimeoutCalculation.calculate_worst_case_timeout(20_971_520, 30_000) == 5_592_405
  end

  test "calculate_worst_case_timeout minimum value" do
    # small data now matter how slow finishes quickly
    # ensure there's a minimum timeout of 60000 ms
    assert TimeoutCalculation.calculate_worst_case_timeout(1, 30_000) == 60000
  end
end
