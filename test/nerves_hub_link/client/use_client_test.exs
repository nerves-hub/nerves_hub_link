# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Client.UseClientTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Client
  alias NervesHubLink.ClientDummy
  alias NervesHubLink.ClientMock

  setup do
    on_exit(fn -> Application.put_env(:nerves_hub_link, :client, ClientMock) end)
  end

  test "update_available/1 uses the override in `ClientDummy`" do
    assert ClientDummy.update_available(nil) == {:reschedule, 1_000}

    Application.put_env(:nerves_hub_link, :client, ClientDummy)

    assert Client.update_available(:data) == {:reschedule, 1_000}
  end

  test "archive_available/1 uses the default from `use Client`" do
    assert ClientDummy.archive_available(nil) == :ignore

    Application.put_env(:nerves_hub_link, :client, ClientDummy)

    assert Client.archive_available(:data) == :ignore
  end
end
