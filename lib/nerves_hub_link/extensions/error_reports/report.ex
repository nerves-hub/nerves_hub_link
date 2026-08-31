# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports.Report do
  @moduledoc """
  One error, in the shape NervesHub stores.

      %{
        "timestamp" => "2026-08-31T10:22:31.123456Z",
        "kind" => "error",
        "reason" => "** (RuntimeError) connection refused",
        "frames" => [%{"module" => "MyApp.Worker", "function" => "handle_info/2", ..}]
      }

  ## `timestamp`, `kind` and `reason` are required

  A report missing any of them is dropped by the server, and dropped quietly:
  no error back to the device and nothing in the UI. The timestamp is when the
  device saw the error rather than when it managed to send it, which is the
  whole point of a report that spent an hour in a buffer waiting for a
  connection.

  ## Frames are not MFAs

  `module` is a namespace string and `function` is a name string, because the
  same shape has to carry a Rust agent's `nerves_hub_link::agent` /
  `run_loop` and an ESP-IDF client's C frames. Nothing on the server reads
  these as Elixir.
  """

  @type t :: %{String.t() => term()}

  # The server caps a reason at 2 KB and a message at 8 KB and truncates past
  # that. Cutting here as well keeps the wire small on a device that is already
  # in trouble.
  @max_reason_bytes 2_048
  @max_message_bytes 8_192

  # The server keeps 30 and drops the rest. Sending more spends the device's
  # bandwidth on frames nobody will read.
  @max_frames 30

  @doc """
  Build a report from an OTP log event carrying a `:crash_reason`.

  Returns `nil` for an event without one, which is every ordinary log line.
  """
  @spec from_log_event(:logger.log_event()) :: t() | nil
  def from_log_event(%{meta: %{crash_reason: {reason, stacktrace}} = meta} = event) do
    {kind, formatted} = describe(reason)

    %{
      "timestamp" => timestamp(meta),
      "kind" => kind,
      "reason" => truncate(formatted, @max_reason_bytes),
      "message" => truncate(message(event[:msg]), @max_message_bytes),
      "source" => "logger",
      "frames" => frames(stacktrace)
    }
  end

  def from_log_event(_event), do: nil

  @doc """
  Build a report from an error the application caught and wants recorded.

  `kind` is `:error`, `:exit` or `:throw`, matching `Kernel.SpecialForms.try/1`.
  """
  @spec from_caught(:error | :exit | :throw, term(), Exception.stacktrace(), keyword()) :: t()
  def from_caught(kind, reason, stacktrace, opts \\ []) do
    %{
      "timestamp" => now(),
      "kind" => to_string(kind),
      "reason" => truncate(Exception.format_banner(kind, reason, stacktrace), @max_reason_bytes),
      "message" => truncate(Exception.format(kind, reason, stacktrace), @max_message_bytes),
      "source" => "manual",
      "frames" => frames(stacktrace)
    }
    |> put_optional("fingerprint", opts[:group])
    |> put_context(opts[:context])
  end

  @doc """
  A report saying how many were dropped, and when the gap opened.

  `at` is the moment the first report was dropped rather than the moment this
  is built, so it sorts ahead of the reports that survived it. It carries its
  own grouping key, so a fleet's dropped-report notices land on one issue
  instead of one per device.
  """
  @spec dropped_notice(pos_integer(), String.t() | nil) :: t()
  def dropped_notice(dropped, at) do
    %{
      "timestamp" => at || now(),
      "kind" => "nerves_hub_link",
      "reason" => "nerves_hub_link dropped #{dropped} error reports to stay inside its buffer",
      "source" => "manual",
      "fingerprint" => "nerves_hub_link:dropped_error_reports",
      "frames" => []
    }
  end

  @doc "Attach device context to a report that does not have any yet."
  @spec put_context(t(), map() | nil) :: t()
  def put_context(report, context) when is_map(context) and map_size(context) > 0 do
    Map.update(report, "context", context, &Map.merge(context, &1))
  end

  def put_context(report, _context), do: report

  @doc "The current time, in the format the server parses."
  @spec now() :: String.t()
  def now(), do: DateTime.to_iso8601(DateTime.utc_now())

  # What `Kernel.SpecialForms.try/1` calls each of these, so the kinds a
  # NervesHub issue is grouped by line up with the words an Elixir developer
  # already uses for them.
  defp describe(%{__exception__: true} = exception) do
    {"error", Exception.format_banner(:error, exception)}
  end

  defp describe({:nocatch, thrown}), do: {"throw", Exception.format_banner(:throw, thrown)}
  defp describe(reason), do: {"exit", Exception.format_banner(:exit, reason)}

  # `:logger` records microseconds since the epoch. Converted here rather than
  # sent raw so the report carries the moment the device saw the error, which
  # is not the moment it got a connection to say so.
  defp timestamp(%{time: time}) when is_integer(time) do
    case DateTime.from_unix(time, :microsecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> now()
    end
  end

  defp timestamp(_meta), do: now()

  defp frames(stacktrace) when is_list(stacktrace) do
    stacktrace |> Enum.take(@max_frames) |> Enum.map(&frame/1)
  end

  defp frames(_stacktrace), do: []

  defp frame({module, function, arity, location}) do
    %{
      "module" => inspect(module),
      "function" => "#{function}/#{arity(arity)}",
      "file" => location |> Keyword.get(:file) |> to_string_or_nil(),
      "line" => Keyword.get(location, :line)
    }
  end

  defp frame({function, arity, location}) do
    %{
      "module" => nil,
      "function" => "#{function}/#{arity(arity)}",
      "file" => location |> Keyword.get(:file) |> to_string_or_nil(),
      "line" => Keyword.get(location, :line)
    }
  end

  # A frame shape this does not know still holds a place in the stacktrace, so
  # it is kept rather than dropped: removing it would shift every frame below
  # it and change which issue the server groups this under.
  defp frame(other),
    do: %{"module" => nil, "function" => inspect(other), "file" => nil, "line" => nil}

  # A stacktrace entry carries the arity, or the arguments themselves when the
  # error came from a function clause that did not match.
  defp arity(arguments) when is_list(arguments), do: length(arguments)
  defp arity(arity) when is_integer(arity), do: arity
  defp arity(_other), do: 0

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # The formatted crash report, which is what a person reads first. `Logger`
  # hands it over as chardata, an OTP report, or a format string and arguments.
  defp message({:string, chardata}), do: to_binary(chardata)
  defp message({:report, report}), do: inspect(report, limit: 50, printable_limit: 4_096)

  defp message({format, args}) when is_list(format) or is_binary(format) do
    format |> :io_lib.format(args) |> to_binary()
  rescue
    _error -> inspect({format, args})
  end

  defp message(nil), do: ""
  defp message(other), do: inspect(other)

  defp to_binary(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    _error -> inspect(chardata)
  end

  defp put_optional(report, _key, nil), do: report
  defp put_optional(report, key, value), do: Map.put(report, key, to_string(value))

  defp truncate(value, max_bytes) do
    if byte_size(value) <= max_bytes do
      value
    else
      # On a code point boundary: cutting mid-character leaves a binary that is
      # no longer valid UTF-8, which the server stores and nothing renders.
      case value |> binary_part(0, max_bytes) |> String.chunk(:valid) do
        [valid | _rest] -> valid
        [] -> ""
      end
    end
  end
end
