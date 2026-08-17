# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.NetworkIdentity do
  @moduledoc """
  The Network Identity Extension.

  Reports the identities this device holds on networks NervesHub does not run —
  an iroh endpoint id, a NetBird or Tailscale peer key, a WireGuard public key —
  so an operator can see them on the device page and reach the device by a route
  other than its NervesHub socket.

  Nothing is reported unless you configure at least one provider, because
  NervesHubLink cannot discover these on its own. See
  `NervesHubLink.Extensions.NetworkIdentity.Provider`.

      config :nerves_hub_link,
        network_identity: [providers: [MyApp.IrohIdentity]]

  Unlike `NervesHubLink.Extensions.Health` and
  `NervesHubLink.Extensions.Geo` there is no interval: an identity is long-lived,
  so NervesHub asks once per connection. If something changes while the device
  stays connected — it moved to a different relay, it was assigned a new overlay
  IP — call `send_report/0` to announce it.
  """

  use NervesHubLink.Extensions, name: "network_identity", version: "0.0.1"

  require Logger

  @doc """
  Report this device's network identities to NervesHub now.

  Only needed when something changed mid-connection; NervesHub asks for a report
  on its own when the extension attaches.

  ## Examples

      iex> NervesHubLink.Extensions.NetworkIdentity.send_report()
      :ok

  """
  @spec send_report() :: :ok | :error
  def send_report() do
    GenServer.call(__MODULE__, :send_report)
  end

  @doc """
  Collect the identities the configured providers report, without sending them.

  Useful from a console when working out why a device isn't showing what you
  expect.
  """
  @spec identities() :: [map()]
  def identities() do
    providers()
    |> Enum.map(&fetch/1)
    |> Enum.reject(&is_nil/1)
  end

  @impl GenServer
  def init(_opts) do
    # Does not report on start, the server asks when it attaches
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:send_report, _from, state) do
    {:reply, report(), state}
  end

  @impl NervesHubLink.Extensions
  def handle_event("request", _msg, state) do
    _ = report()
    {:noreply, state}
  end

  defp report() do
    identities = identities()

    if identities == [] and providers() == [] do
      # The server only asks when an operator has switched this on, so being
      # asked with nothing configured is worth saying out loud.
      Logger.warning(
        "[#{inspect(__MODULE__)}] NervesHub asked for network identities but no providers are configured"
      )
    end

    case push("report", %{identities: identities}) do
      {:ok, _ref} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp fetch(provider) do
    case provider.identity() do
      {:ok, identity} ->
        normalize(provider, identity)

      :unavailable ->
        # Routine on a device that simply isn't on this network, so debug —
        # a warning here would fire on every reconnect and stop meaning anything.
        Logger.debug("[#{inspect(__MODULE__)}] #{inspect(provider)} has no identity to report")
        nil

      {:error, reason} ->
        Logger.warning(
          "[#{inspect(__MODULE__)}] #{inspect(provider)} failed to resolve an identity: #{inspect(reason)}"
        )

        nil

      other ->
        Logger.warning(
          "[#{inspect(__MODULE__)}] #{inspect(provider)} returned #{inspect(other, limit: 5)}, " <>
            "expected {:ok, identity}, :unavailable or {:error, reason}"
        )

        nil
    end
  rescue
    error ->
      # A broken provider must not take down the extension, and the extension
      # must not take down the socket.
      Logger.warning(
        "[#{inspect(__MODULE__)}] #{inspect(provider)} raised: #{Exception.message(error)}"
      )

      nil
  end

  # Providers are written by hand, so accept either key style rather than
  # silently dropping an identity over an atom-versus-string mistake.
  defp normalize(provider, %{service: service, identifier: identifier} = identity) do
    build(provider, %{
      service: service,
      identifier: identifier,
      instance: Map.get(identity, :instance),
      details: Map.get(identity, :details, %{})
    })
  end

  defp normalize(provider, %{"service" => service, "identifier" => identifier} = identity) do
    build(provider, %{
      service: service,
      identifier: identifier,
      instance: Map.get(identity, "instance"),
      details: Map.get(identity, "details", %{})
    })
  end

  defp normalize(provider, other) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] #{inspect(provider)} returned an identity without " <>
        ":service and :identifier: #{inspect(other, limit: 5)}"
    )

    nil
  end

  defp build(_provider, %{identifier: identifier} = fields) when is_binary(identifier) do
    %{
      service: to_string(fields.service),
      identifier: identifier,
      details: (is_map(fields.details) && fields.details) || %{}
    }
    |> put_instance(fields.instance)
  end

  defp build(provider, %{identifier: identifier}) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] #{inspect(provider)} returned a non-string identifier: " <>
        inspect(identifier, limit: 5)
    )

    nil
  end

  # Left out entirely when a provider doesn't name one, so NervesHub applies its
  # own default rather than us guessing at the name for it.
  defp put_instance(identity, nil), do: identity
  defp put_instance(identity, ""), do: identity

  defp put_instance(identity, instance) when is_binary(instance) or is_atom(instance),
    do: Map.put(identity, :instance, to_string(instance))

  defp put_instance(identity, _instance), do: identity

  @spec providers() :: [module()]
  defp providers() do
    :nerves_hub_link
    |> Application.get_env(:network_identity, [])
    |> Keyword.get(:providers, [])
    |> List.wrap()
  end
end
