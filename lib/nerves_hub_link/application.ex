# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2026 Eliel A. Gordon
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if auto_start?() and connect?() do
        [NervesHubLink.Supervisor]
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: NervesHubLink.ApplicationSupervisor
    )
  end

  # When `:start` is `:manual`, the user adds `NervesHubLink.Supervisor` to
  # their own supervision tree instead of having the application do it. The
  # default `:auto` preserves the historical auto-start behaviour.
  defp auto_start?() do
    Application.get_env(:nerves_hub_link, :start, :auto) == :auto
  end

  defp connect?() do
    Application.get_env(:nerves_hub_link, :connect, true)
  end
end
