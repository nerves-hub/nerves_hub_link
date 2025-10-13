# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
if Code.ensure_loaded?(ExPTY) do
  defmodule NervesHubLink.Extensions.LocalShell do
    @moduledoc """
    Provides an interactive local shell for NervesHub to connect to.

    This extension supports the following events:

    - `request_shell`: Requests a shell session.
    - `kill_shell`: Kills the current shell session. (the default signal is 15 - SIGTERM)
    - `shell_input`: Sends input to the shell session.
    - `window_size`: Updates the window size of the shell session.

    To use this extension, you need to include the [`ExPTY`](https://hex.pm/packages/expty) library in your project's dependencies.
    """

    use NervesHubLink.Extensions, name: "local_shell", version: "0.0.1"

    require Logger

    @impl GenServer
    def init(_opts) do
      {:ok,
       %{
         pty_pid: nil,
         pty_opts: nil
       }}
    end

    @impl NervesHubLink.Extensions
    # shell is already running
    def handle_event("request_shell", _msg, %{pty_pid: pty_pid} = state)
        when not is_nil(pty_pid) do
      {:noreply, state}
    end

    def handle_event("request_shell", _msg, state) do
      case exec_command(get_shell_command(), state) do
        {:ok, pty_pid, _} ->
          {:ok, _} = push("request_status", %{"status" => "started"})
          {:noreply, %{state | pty_pid: pty_pid}}

        {:error, reason} ->
          Logger.error("[Extensions.LocalShell] Failed to start shell: #{inspect(reason)}")
          {:ok, _} = push("request_status", %{"status" => "failed", "reason" => reason})
          {:noreply, state}
      end
    end

    # Noop events when the `pty_pid` is not set.
    def handle_event(_, _msg, %{pty_pid: pty_pid} = state) when is_nil(pty_pid) do
      {:noreply, state}
    end

    def handle_event("kill_shell", msg, state) do
      signal = if is_map(msg), do: Map.get(msg, "signal", 15), else: 15
      :ok = ExPTY.kill(state.pty_pid, signal)
      {:noreply, %{state | pty_pid: nil}}
    end

    def handle_event("shell_input", %{"data" => data}, state) do
      :ok = ExPTY.write(state.pty_pid, data)
      {:noreply, state}
    end

    def handle_event("window_size", %{"rows" => rows, "cols" => cols}, state) do
      :ok = ExPTY.resize(state.pty_pid, cols, rows)
      {:noreply, state}
    end

    @impl GenServer
    def handle_info({:pty_data, pty_pid, data}, %{pty_pid: pty_pid} = state) do
      {:ok, _} = push("shell_output", %{"data" => data})
      {:noreply, state}
    end

    def handle_info({:pty_exit, pty_pid, exit_code}, %{pty_pid: pty_pid} = state) do
      {:ok, _} = push("shell_exited", %{"exit_code" => exit_code})
      {:noreply, %{state | pty_pid: nil}}
    end

    defp exec_command(cmd, %{pty_opts: pty_opts}) do
      [file | args] = cmd
      parent = self()

      env =
        System.get_env()
        |> Map.put_new("TERM", get_term(pty_opts))

      opts = [
        env: env,
        on_data: fn _expty, pty_pid, data -> send(parent, {:pty_data, pty_pid, data}) end,
        on_exit: fn _expty, pty_pid, exit_code, _signal_code ->
          send(parent, {:pty_exit, pty_pid, exit_code})
        end
      ]

      opts =
        case pty_opts do
          nil ->
            opts

          {_term, cols, rows, _, _, _} ->
            opts ++ [cols: cols, rows: rows]
        end

      case ExPTY.spawn(file, args, opts) do
        {:ok, pty_pid} ->
          {:ok, pty_pid, pty_pid}

        error ->
          error
      end
    end

    defp get_shell_command() do
      cond do
        shell = System.get_env("SHELL") ->
          [shell, "-i"]

        shell = System.find_executable("sh") ->
          [shell, "-i"]

        true ->
          raise "SHELL environment variable not set and sh not available"
      end
    end

    defp get_term(nil) do
      if term = System.get_env("TERM") do
        term
      else
        "xterm"
      end
    end

    # erlang pty_ch_msg contains the value of TERM
    # https://www.erlang.org/doc/man/ssh_connection.html#type-pty_ch_msg
    defp get_term({term, _, _, _, _, _} = _pty_ch_msg) when is_list(term),
      do: List.to_string(term)
  end
else
  defmodule NervesHubLink.Extensions.LocalShell do
    @moduledoc false

    use NervesHubLink.Extensions, name: "local_shell", version: "0.0.1"

    require Logger

    @impl GenServer
    def init(_opts) do
      {:ok, %{}}
    end

    @impl NervesHubLink.Extensions
    def handle_event("request_shell", _msg, state) do
      message = "`:expty` not included in project dependencies"
      Logger.error("[Extensions.LocalShell] Failed to start shell: #{message}")
      {:ok, _} = push("request_status", %{"status" => "failed", "reason" => message})
      {:noreply, state}
    end

    def handle_event(_, _, state) do
      {:noreply, state}
    end
  end
end
