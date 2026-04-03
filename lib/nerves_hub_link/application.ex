# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Application do
  @moduledoc false
  use Application

  alias NervesHubLink.Configurator

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:nerves_hub_link, :connect, true) do
        [{NervesHubLink, Configurator.build()}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesHubLink.Supervisor)
  end
end
