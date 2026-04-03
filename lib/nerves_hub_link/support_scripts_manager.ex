# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SupportScriptsManager do
  @moduledoc false
  # Executes support scripts on the device, sends the results to Hub (via Socket),
  # and makes sure the scripts don't run forever.

  use GenServer

  alias NervesHubLink.Socket

  require Logger

  @default_timeout 10_000

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(identifier) when is_binary(identifier) do
    name = NervesHubLink.__process_name__(identifier, __MODULE__)
    GenServer.start_link(__MODULE__, identifier, name: name)
  end

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @doc """
  Starts a task to execute a support script on the device.
  """
  @spec start_task(
          GenServer.server(),
          identifier :: String.t(),
          script :: String.t(),
          timeout :: non_neg_integer(),
          handler :: any()
        ) :: :ok
  def start_task(server \\ __MODULE__, identifier, script, timeout, handler \\ Socket) do
    timeout = timeout || @default_timeout
    GenServer.cast(server, {:start_task, script, identifier, timeout, handler})
  end

  @impl GenServer
  def init(identifier) do
    {:ok, %{identifier: identifier, running_scripts: %{}}}
  end

  @impl GenServer
  def handle_cast({:start_task, script, identifier, timeout, handler}, state) do
    %{running_scripts: running} = state
    task_sup = task_supervisor_name(state)

    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
        # Inspired from ExUnit.CaptureIO
        # https://github.com/elixir-lang/elixir/blob/main/lib/ex_unit/lib/ex_unit/capture_io.ex
        {:ok, string_io} = StringIO.open("")

        Process.group_leader(self(), string_io)

        try do
          Code.eval_string(script)
        catch
          kind, reason ->
            {:ok, {_input, output}} = StringIO.close(string_io)
            result = Exception.format_banner(kind, reason, __STACKTRACE__)
            output = output <> "\n" <> result
            {nil, output}
        else
          {result, _binding} ->
            {:ok, {_input, output}} = StringIO.close(string_io)
            {result, output}
        end
      end)

    timeout = Process.send_after(self(), {:timeout, task}, timeout)

    details = %{timeout_pid: timeout, identifier: identifier, handler: handler}

    {:noreply, %{state | running_scripts: Map.put(running, task.ref, details)}}
  end

  # the timeout fired
  @impl GenServer
  def handle_info({:timeout, task}, state) do
    %{running_scripts: running} = state
    task_info = running[task.ref]

    _ = Task.shutdown(task, :brutal_kill)

    Logger.info(
      "Script killed due to timeout : ref:#{inspect(task.ref)} identifier:#{inspect(task_info.identifier)}"
    )

    send(task_info.handler, {"scripts/result", task_info.identifier, {:error, :timeout}})

    {:noreply, %{state | running_scripts: Map.delete(running, task.ref)}}
  end

  # The task completed successfully
  def handle_info({ref, {result, output}}, state) do
    %{running_scripts: running} = state
    task_info = running[ref]

    _ = Process.cancel_timer(task_info.timeout_pid)

    Logger.info(
      "Script completed successfully : ref:#{inspect(ref)} identifier:#{inspect(task_info.identifier)}"
    )

    send(task_info.handler, {"scripts/result", task_info.identifier, {:ok, result, output}})

    Process.demonitor(ref, [:flush])

    {:noreply, %{state | running_scripts: Map.delete(running, ref)}}
  end

  # The task failed
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    %{running_scripts: running} = state
    task_info = running[ref]

    Logger.info(
      "Script encountered an error : ref:#{inspect(ref)} identifier:#{inspect(task_info.identifier)} - #{inspect(reason)}"
    )

    _ = Process.cancel_timer(task_info.timeout_pid)

    send(task_info.handler, {"scripts/result", task_info.identifier, {:error, reason}})

    {:noreply, %{state | running_scripts: Map.delete(running, ref)}}
  end

  defp task_supervisor_name(%{identifier: nil}), do: SupportScriptsTaskSupervisor

  defp task_supervisor_name(%{identifier: id}),
    do: NervesHubLink.__process_name__(id, SupportScriptsTaskSupervisor)
end
