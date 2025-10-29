# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SupportScriptsManager do
  @moduledoc """
  Executes support scripts on the device, sends the results to Hub (via Socket),
  and makes sure the scripts don't run forever.
  """
  use GenServer

  alias NervesHubLink.Socket

  require Logger

  @default_timeout 10_000

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], opts)
  end

  @doc """
  Starts a task to execute a support script on the device.
  """
  @spec start_task(
          identifier :: String.t(),
          script :: String.t(),
          timeout :: non_neg_integer(),
          handler :: any()
        ) :: :ok
  def start_task(identifier, script, timeout, handler \\ Socket) do
    timeout = timeout || @default_timeout
    GenServer.cast(__MODULE__, {:start_task, script, identifier, timeout, handler})
  end

  @impl GenServer
  def init(_) do
    {:ok, %{running_scripts: %{}}}
  end

  @impl GenServer
  def handle_cast({:start_task, script, identifier, timeout, handler}, %{running_scripts: running}) do
    task =
      Task.Supervisor.async_nolink(SupportScriptsTaskSupervisor, fn ->
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

    {:noreply, %{running_scripts: Map.put(running, task.ref, details)}}
  end

  # the timeout fired
  @impl GenServer
  def handle_info({:timeout, task}, %{running_scripts: running}) do
    task_info = running[task.ref]

    _ = Task.shutdown(task, :brutal_kill)

    Logger.info(
      "Script killed due to timeout : ref:#{inspect(task.ref)} identifier:#{inspect(task_info.identifier)}"
    )

    send(task_info.handler, {"scripts/result", task_info.identifier, {:error, :timeout}})

    {:noreply, %{running_scripts: Map.delete(running, task.ref)}}
  end

  # The task completed successfully
  def handle_info({ref, {result, output}}, %{running_scripts: running}) do
    task_info = running[ref]

    _ = Process.cancel_timer(task_info.timeout_pid)

    Logger.info(
      "Script completed successfully : ref:#{inspect(ref)} identifier:#{inspect(task_info.identifier)}"
    )

    send(task_info.handler, {"scripts/result", task_info.identifier, {:ok, result, output}})

    Process.demonitor(ref, [:flush])

    {:noreply, %{running_scripts: Map.delete(running, ref)}}
  end

  # The task failed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running_scripts: running}) do
    task_info = running[ref]

    Logger.info(
      "Script encountered an error : ref:#{inspect(ref)} identifier:#{inspect(task_info.identifier)} - #{inspect(reason)}"
    )

    _ = Process.cancel_timer(task_info.timeout_pid)

    send(task_info.handler, {"scripts/result", task_info.identifier, {:error, reason}})

    {:noreply, %{running_scripts: Map.delete(running, ref)}}
  end
end
