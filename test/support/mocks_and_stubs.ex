# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ClientStub do
  @behaviour NervesHubLink.Client
  def reboot(), do: :ok
  def archive_available(_), do: :ignore
  def archive_ready(_, _), do: :ok
  def handle_error(_), do: :ok
  def handle_fwup_message(_), do: :ok
  def identify(), do: :ok
  def update_available(_), do: :apply
end
