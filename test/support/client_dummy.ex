# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
defmodule NervesHubLink.ClientDummy do
  @moduledoc false
  use NervesHubLink.Client

  @impl NervesHubLink.Client
  def update_available(_update_info) do
    {:reschedule, 1_000}
  end
end
