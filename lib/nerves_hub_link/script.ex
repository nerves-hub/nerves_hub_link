defmodule NervesHubLink.Script do
  @moduledoc false

  # Mechanism for running scripts from NervesHub on device.

  use GenServer

  @doc """
  Run a script from NervesHub and capture its output
  """
  @spec capture(String.t(), any()) :: :ok
  def capture(text, ref) do
    _ = GenServer.start_link(__MODULE__, {self(), text, ref})

    :ok
  end

  @impl GenServer
  def init({pid, text, ref}) do
    state = %{pid: pid, text: text, ref: ref}
    {:ok, state, {:continue, :capture}}
  end

  @impl GenServer
  def handle_continue(:capture, state) do
    # Inspired from ExUnit.CaptureIO
    # https://github.com/elixir-lang/elixir/blob/main/lib/ex_unit/lib/ex_unit/capture_io.ex
    {:ok, string_io} = StringIO.open("")

    Process.group_leader(self(), string_io)

    {result, output} =
      try do
        Code.eval_string(state.text)
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

    send(state.pid, {"scripts/run", state.ref, output, result})

    {:stop, :normal, state}
  end
end
