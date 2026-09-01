# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components do
  @moduledoc """
  The Components Extension.

  Reports the hardware topology of the device to NervesHub — what the device
  is made of, and what is talking to it — and carries out the actions and mode
  changes an operator requests against that topology.

  The topology gives shape to what the device already reports through the
  Health extension: it names the metrics and metadata keys that belong to each
  part of the device, so NervesHub can show a temperature sensor as a box with
  its readings rather than a flat list of numbers.

  ## Structure

  - **Assembly** — a grouping of components that are part of the device
    (a display, an environment sensor cluster, the networking hardware).
    - **Component** — one part of the device.
  - **Network** — a grouping of peers the device talks to (a Z-Wave network,
    a fleet of BLE sensors).
    - **Peer** — one device communicating with this device.

  An assembly and a network are structurally the same, as are a component and
  a peer: the split says whether the thing is *part of* the device or
  *connected to* it, so NervesHub can shape the UI accordingly.

  Components and peers can expose:

  - `metrics` — health metric keys (numbers) that belong to this part
  - `metadata` — health metadata keys (strings) that belong to this part
  - `actions` — operations an operator can invoke, each bound to a local
    handler. NervesHub only ever sees the identifier and label; what the
    action does stays on the device. Invocation arrives as an explicit
    message, not over the console channel, so it works for fleets that keep
    the remote console disabled.
  - `modes` — a selectable value (a display's day/night mode). The list of
    values is reported with the topology; the *current* value is read from
    the health metadata entry named by `metadata_key` (defaulting to the
    mode's identifier), so keep that metadata entry up to date. A selection
    is applied through the mode's handler.

  ## Configuration

  Fixed topology goes in config:

      config :nerves_hub_link,
        components: [
          assemblies: [
            %{
              identifier: "display",
              label: "Display",
              components: [
                %{
                  identifier: "panel",
                  label: "Panel",
                  metrics: ["display_fps", "ambient_light_lux"],
                  metadata: ["panel_firmware"],
                  actions: [
                    %{
                      identifier: "recalibrate",
                      label: "Recalibrate touch",
                      handler: {MyApp.Display, :recalibrate, []}
                    }
                  ],
                  modes: [
                    %{
                      identifier: "display_mode",
                      label: "Display mode",
                      values: ["day", "night", "auto"],
                      handler: {MyApp.Display, :set_mode, []}
                    }
                  ]
                }
              ]
            }
          ]
        ]

  Topology that only exists at runtime (the peers on a Z-Wave network, a
  hot-plugged expansion board) comes from sources — modules implementing
  `NervesHubLink.Extensions.Components.Source`:

      config :nerves_hub_link,
        components: [sources: [MyApp.ZWaveTopology]]

  Sources are consulted every time a report is built. When a source's answer
  changes, call `report_topology/0` to push a fresh report.

  Component and peer identifiers must be unique across the whole device —
  actions and modes are addressed by `{component identifier, action
  identifier}`.

  ## Handlers

  An action handler is an MFA or a function. An MFA `{m, f, a}` is applied
  as-is; a 0-arity function is called; a 1-arity function receives the params
  map sent with the invocation (usually empty). A mode handler receives the
  selected value: `{m, f, a}` is applied with the value appended to `a`, a
  1-arity function is called with the value.

  Handlers run in a separate monitored process with a timeout
  (`action_timeout`, default 60 seconds):

      config :nerves_hub_link,
        components: [action_timeout: to_timeout(second: 30)]

  The handler's return value is inspected and sent back as the result output,
  truncated to 4096 bytes. A raised exception or crash is reported as an
  error result rather than taking the extension down.
  """

  use NervesHubLink.Extensions, name: "components", version: "0.0.1"

  alias NervesHubLink.Extensions.Components.Topology

  require Logger

  @default_action_timeout 60_000
  @max_output_bytes 4096

  @doc """
  Build and push a fresh topology report to NervesHub.

  NervesHub asks for the topology when the extension attaches; call this when
  the topology changes at runtime (a source's answer changed) so NervesHub is
  not left holding a stale picture.
  """
  @spec report_topology() :: :ok | {:error, :detached | term()}
  def report_topology() do
    case push("report", Topology.report()) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{runs: %{}}}
  end

  @impl NervesHubLink.Extensions
  def handle_event("request", _payload, state) do
    _ = report_topology()
    {:noreply, state}
  end

  def handle_event(
        "action:run",
        %{"ref" => ref, "component" => component, "action" => action} = payload,
        state
      )
      when is_binary(ref) and is_binary(component) and is_binary(action) do
    context = %{"component" => component, "action" => action}

    case Topology.fetch_action(component, action) do
      {:ok, handler} ->
        params = if(is_map(payload["params"]), do: payload["params"], else: %{})
        {:noreply, start_run(state, ref, "action:result", context, run_action(handler, params))}

      :error ->
        _ = push_result("action:result", ref, context, {:error, "unknown action"})
        {:noreply, state}
    end
  end

  def handle_event(
        "mode:set",
        %{"ref" => ref, "component" => component, "mode" => mode, "value" => value},
        state
      )
      when is_binary(ref) and is_binary(component) and is_binary(mode) and is_binary(value) do
    context = %{"component" => component, "mode" => mode, "value" => value}

    case Topology.fetch_mode(component, mode) do
      {:ok, {handler, values}} ->
        if values == [] or value in values do
          {:noreply, start_run(state, ref, "mode:result", context, run_mode(handler, value))}
        else
          _ = push_result("mode:result", ref, context, {:error, "invalid value"})
          {:noreply, state}
        end

      :error ->
        _ = push_result("mode:result", ref, context, {:error, "unknown mode"})
        {:noreply, state}
    end
  end

  def handle_event(event, payload, state) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] unexpected event #{inspect(event)}: #{inspect(payload)}"
    )

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:run_result, pid, result}, state) do
    case Map.pop(state.runs, pid) do
      {nil, _runs} ->
        # A run that already timed out; its result no longer has a taker.
        {:noreply, state}

      {run, runs} ->
        _ = :timer.cancel(run.timer)
        Process.demonitor(run.monitor, [:flush])
        _ = push_result(run.event, run.ref, run.context, result)
        {:noreply, %{state | runs: runs}}
    end
  end

  def handle_info({:DOWN, _monitor_ref, :process, pid, reason}, state) do
    case Map.pop(state.runs, pid) do
      {nil, _runs} ->
        {:noreply, state}

      {run, runs} ->
        # The run died before it could send a result.
        _ = :timer.cancel(run.timer)
        _ = push_result(run.event, run.ref, run.context, {:error, "crashed: #{inspect(reason)}"})
        {:noreply, %{state | runs: runs}}
    end
  end

  def handle_info({:run_timeout, pid}, state) do
    case Map.pop(state.runs, pid) do
      {nil, _runs} ->
        {:noreply, state}

      {run, runs} ->
        Process.demonitor(run.monitor, [:flush])
        Process.exit(pid, :kill)
        _ = push_result(run.event, run.ref, run.context, {:error, "timeout"})
        {:noreply, %{state | runs: runs}}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[#{inspect(__MODULE__)}] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp start_run(state, ref, event, context, fun) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, format_output(fun.())}
          rescue
            error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
          catch
            kind, value -> {:error, Exception.format(kind, value, __STACKTRACE__)}
          end

        send(parent, {:run_result, self(), result})
      end)

    {:ok, timer} = :timer.send_after(action_timeout(), {:run_timeout, pid})

    run = %{ref: ref, event: event, context: context, monitor: monitor_ref, timer: timer}
    %{state | runs: Map.put(state.runs, pid, run)}
  end

  defp run_action({m, f, a}, _params), do: fn -> apply(m, f, a) end
  defp run_action(fun, _params) when is_function(fun, 0), do: fun
  defp run_action(fun, params) when is_function(fun, 1), do: fn -> fun.(params) end

  defp run_mode({m, f, a}, value), do: fn -> apply(m, f, a ++ [value]) end
  defp run_mode(fun, value) when is_function(fun, 1), do: fn -> fun.(value) end
  defp run_mode(fun, _value) when is_function(fun, 0), do: fun

  defp push_result(event, ref, context, result) do
    {status, output} =
      case result do
        {:ok, output} -> {"ok", output}
        {:error, output} -> {"error", truncate(to_string(output))}
      end

    payload =
      context
      |> Map.put("ref", ref)
      |> Map.put("status", status)
      |> Map.put("output", output)

    case push(event, payload) do
      {:ok, _push_ref} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[#{inspect(__MODULE__)}] could not deliver #{event} for ref #{ref}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp format_output(:ok), do: ""

  defp format_output(output) when is_binary(output) do
    if String.valid?(output) do
      truncate(output)
    else
      truncate(inspect(output, limit: 50))
    end
  end

  defp format_output(output), do: truncate(inspect(output, pretty: true, limit: 50))

  defp truncate(output) do
    if byte_size(output) > @max_output_bytes do
      # Re-validate after the byte cut so a split multi-byte character cannot
      # make the payload unencodable.
      truncated = binary_part(output, 0, @max_output_bytes)
      valid = for <<char::utf8 <- truncated>>, into: "", do: <<char::utf8>>
      valid <> "…"
    else
      output
    end
  end

  defp action_timeout() do
    :nerves_hub_link
    |> Application.get_env(:components, [])
    |> Keyword.get(:action_timeout, @default_action_timeout)
    |> max(100)
  end
end
