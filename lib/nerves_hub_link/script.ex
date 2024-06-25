defmodule NervesHubLink.Script do
  # Inspired from ExUnit.CaptureIO
  # https://github.com/elixir-lang/elixir/blob/main/lib/ex_unit/lib/ex_unit/capture_io.ex

  @doc """
  Run a script from NervesHub and capture its output
  """
  def capture(text) do
    original_gl = Process.group_leader()
    {:ok, string_io} = StringIO.open("")

    try do
      Process.group_leader(self(), string_io)

      try do
        Code.eval_string(text)
      catch
        kind, reason ->
          {:ok, {_input, output}} = StringIO.close(string_io)
          result = Exception.format_banner(kind, reason, __STACKTRACE__)
          output = output <> "\n" <> result
          {nil, output}
      else
        result ->
          {:ok, {_input, output}} = StringIO.close(string_io)
          {result, output}
      end
    after
      Process.group_leader(self(), original_gl)
    end
  end
end
