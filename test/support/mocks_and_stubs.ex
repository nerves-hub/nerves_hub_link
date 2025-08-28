# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ClientStub do
  @moduledoc false
  @behaviour NervesHubLink.Client

  @impl NervesHubLink.Client
  def archive_available(_), do: :ignore

  @impl NervesHubLink.Client
  def archive_ready(_, _), do: :ok

  @impl NervesHubLink.Client
  def handle_error(_), do: :ok

  @impl NervesHubLink.Client
  def handle_fwup_message(_), do: :ok

  @impl NervesHubLink.Client
  def identify(), do: :ok

  @impl NervesHubLink.Client
  def reboot(), do: :ok

  @impl NervesHubLink.Client
  def update_available(_), do: :apply
end
