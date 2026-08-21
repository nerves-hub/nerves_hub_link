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

  ## When identities are sent

  NervesHub asks for all of them once, when the extension attaches. After that
  the device checks its own providers every `interval_minutes` and sends **only
  what changed**.

      config :nerves_hub_link,
        network_identity: [
          providers: [MyApp.IrohIdentity],
          interval_minutes: 5
        ]

  The polling is not about the identifier, which does not move: a key is a key.
  It is about everything a provider puts beside it. A device that switches relay
  keeps its endpoint id and changes the address anyone would reach it on, and a
  stale address is worse than no address when it is the only route to the device.

  Nothing goes over the wire when nothing has changed, so the interval costs one
  local call per provider and no traffic. Set `interval_minutes: 0` to switch the
  poll off and send only on connect.

  A provider that knows the moment its identity changed need not wait for the
  poll — see `send_identity/1`.
  """

  use NervesHubLink.Extensions, name: "network_identity", version: "0.0.1"

  require Logger

  @default_interval_minutes 5

  @doc """
  Send every configured provider's identity to NervesHub now.

  Sends all of them whether or not they have changed, which is what the poll
  deliberately avoids doing. Rarely needed by hand: NervesHub asks on connect,
  and the poll notices anything that moves after that.

  ## Examples

      iex> NervesHubLink.Extensions.NetworkIdentity.send_identities()
      :ok

  """
  @spec send_identities() :: :ok | :error
  def send_identities() do
    GenServer.call(__MODULE__, :send_identities)
  end

  @doc """
  Send one provider's identity to NervesHub now.

  For a provider that knows the moment its identity changed and would rather say
  so than wait up to `interval_minutes` for the poll to notice — a library that
  already watches its own relay assignment, say.

      NervesHubLink.Extensions.NetworkIdentity.send_identity(MyApp.IrohIdentity)

  What is sent updates what the poll considers current, so announcing a change
  this way does not make the next poll send it a second time.

  Returns `:error` when the provider has nothing to report or the socket is
  detached. Neither is worth handling: the poll picks the identity up once it is
  available and the connection is back.
  """
  @spec send_identity(module()) :: :ok | :error
  def send_identity(provider) when is_atom(provider) do
    GenServer.call(__MODULE__, {:send_identity, provider})
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
    # Nothing is sent on start: the server asks when the extension attaches, and
    # a push before that is dropped as detached anyway.
    #
    # `sent` is what NervesHub was last told, per provider. Without it the poll
    # has nothing to compare against and every interval becomes a write on the
    # server for data that has not moved.
    {:ok, schedule_poll(%{sent: %{}})}
  end

  @impl GenServer
  def handle_call(:send_identities, _from, state) do
    {result, state} = send_all(state)
    {:reply, result, state}
  end

  def handle_call({:send_identity, provider}, _from, state) do
    case fetch(provider) do
      nil ->
        {:reply, :error, state}

      identity ->
        case deliver(%{provider => identity}) do
          :ok -> {:reply, :ok, put_in(state.sent[provider], identity)}
          :error -> {:reply, :error, state}
        end
    end
  end

  @impl NervesHubLink.Extensions
  def handle_event("request", _msg, state) do
    # Everything, not just what changed. A server that has just asked may be a
    # different one, or the same one having forgotten — either way it is not
    # holding what our cache says it is.
    {_result, state} = send_all(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    current = current_identities()

    changed =
      Map.reject(current, fn {provider, identity} -> Map.get(state.sent, provider) == identity end)

    state =
      case deliver(changed) do
        :ok ->
          log_change(changed)
          # `current` rather than a merge, so a provider that has stopped
          # answering is forgotten and re-sent if it comes back.
          %{state | sent: current}

        :error ->
          # Detached, most likely. Leave the cache alone so this is retried
          # rather than treated as delivered.
          state
      end

    {:noreply, schedule_poll(state)}
  end

  defp send_all(state) do
    current = current_identities()

    if current == %{} and providers() == [] do
      # The server only asks when an operator has switched this on, so being
      # asked with nothing configured is worth saying out loud.
      Logger.warning(
        "[#{inspect(__MODULE__)}] NervesHub asked for network identities but no providers are configured"
      )
    end

    case deliver(current) do
      :ok -> {:ok, %{state | sent: current}}
      :error -> {:error, state}
    end
  end

  # One push carrying however many identities. The server records each one on
  # its own, so a partial list is a partial update and never a replacement —
  # which is what makes sending only the changed ones safe.
  defp deliver(identities) when map_size(identities) == 0, do: :ok

  defp deliver(identities) do
    case push("report", %{identities: Map.values(identities)}) do
      {:ok, _ref} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp current_identities() do
    providers()
    |> Enum.map(fn provider -> {provider, fetch(provider)} end)
    |> Enum.reject(fn {_provider, identity} -> is_nil(identity) end)
    |> Map.new()
  end

  defp log_change(changed) when map_size(changed) == 0, do: :ok

  defp log_change(changed) do
    Logger.debug(
      "[#{inspect(__MODULE__)}] sent #{map_size(changed)} changed " <>
        "#{(map_size(changed) == 1 && "identity") || "identities"} to NervesHub"
    )
  end

  defp schedule_poll(state) do
    case interval() do
      nil -> state
      interval -> _ = Process.send_after(self(), :poll, interval)
    end

    state
  end

  # Minutes rather than milliseconds, to match the other extensions' intervals.
  # `to_timeout/1` would read better but arrived in Elixir 1.17 and this library
  # still supports 1.15.
  #
  # Public only so the config can be tested. Absence of a timer five minutes out
  # is not something a test can observe by waiting.
  @doc false
  @spec interval() :: pos_integer() | nil
  def interval() do
    :nerves_hub_link
    |> Application.get_env(:network_identity, [])
    |> Keyword.get(:interval_minutes, @default_interval_minutes)
    |> case do
      minutes when is_integer(minutes) and minutes > 0 -> minutes * 60_000
      _off -> nil
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
