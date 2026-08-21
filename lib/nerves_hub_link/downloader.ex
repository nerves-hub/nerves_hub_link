# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Downloader do
  @moduledoc """
  Handles downloading files via HTTP.

  Several interesting properties about the download are internally cached, such as:

    * the URI of the request
    * the total content amounts of bytes of the file being downloaded
    * the total amount of bytes downloaded at any given time

  Using this information, it can restart a download using the
  [`Range` HTTP header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Range).

  This process's **only** focus is obtaining data reliably. It doesn't have any
  side effects on the system.

  You can configure various options related to how the `Downloader` handles timeouts,
  disconnections, and other aspects of the retry logic by adding the following configuration
  to your application's config file:

      config :nerves_hub_link, :retry_config,
        max_disconnects: 20,
        idle_timeout: 75_000,
        max_timeout: 10_800_000

  For more information about the configuration options, see the [RetryConfig](`NervesHubLink.Downloader.RetryConfig`) module.
  """

  use GenServer

  alias NervesHubLink.Downloader
  alias NervesHubLink.Downloader.RetryConfig
  alias NervesHubLink.Downloader.TimeoutCalculation
  alias NervesHubLink.NetworkInterface

  require Logger
  require Mint.HTTP

  defstruct uri: nil,
            conn: nil,
            request_ref: nil,
            status: nil,
            completed: false,
            response_headers: [],
            content_length: 0,
            downloaded_length: 0,
            retry_number: 0,
            handler_fun: nil,
            retry_args: nil,
            transport_opts: [],
            http_opts: [],
            max_timeout: nil,
            resume_from_bytes: nil,
            range_end: nil,
            label: nil,
            retry_timeout: nil,
            worst_case_timeout: nil,
            worst_case_timeout_remaining_ms: nil

  @type handler_event ::
          {:data, data :: binary(), percent_complete :: float()} | {:error, any()} | :complete
  @type event_handler_fun :: (handler_event -> any())
  @type retry_args :: RetryConfig.t()

  # alias for readability
  @typep timer() :: reference()

  @type t :: %Downloader{
          uri: nil | URI.t(),
          conn: nil | Mint.HTTP.t(),
          request_ref: nil | reference(),
          status: nil | Mint.Types.status(),
          completed: boolean(),
          response_headers: Mint.Types.headers(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          resume_from_bytes: nil | non_neg_integer(),
          range_end: nil | non_neg_integer(),
          label: nil | String.t(),
          retry_number: non_neg_integer(),
          handler_fun: event_handler_fun,
          retry_args: retry_args(),
          transport_opts: keyword(),
          http_opts: keyword(),
          max_timeout: timer(),
          retry_timeout: nil | timer(),
          worst_case_timeout: nil | timer(),
          worst_case_timeout_remaining_ms: nil | non_neg_integer()
        }

  @type initialized_download :: %Downloader{
          uri: URI.t(),
          conn: Mint.HTTP.t(),
          request_ref: reference(),
          status: nil | Mint.Types.status(),
          response_headers: Mint.Types.headers(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          retry_number: non_neg_integer(),
          handler_fun: event_handler_fun
        }

  # todo, this should be `t`, but with retry_timeout
  @type resume_rescheduled :: t()

  @type option ::
          {:resume_from_bytes, integer()}
          | {:range_end, integer()}
          | {:label, String.t()}
          | {:retry_config, RetryConfig.t()}
          | {:downloader_ssl, keyword()}
          | {:downloader_http_opts, keyword()}
  @type options :: [option()]

  @doc """
  Begins downloading a file at `url` handled by `fun`.

  Pass `:resume_from_bytes` to start part way into the file, and `:range_end`
  (the offset of the last byte wanted, counting from the start of the file) to
  stop before the end of it. Together they fetch one slice of a file, which is
  what lets several downloads share a file without overlapping.

  When several downloads are running at once, pass `:label` to say which is
  which. It is added to every log line this process writes, which are otherwise
  impossible to tell apart.

  # Example

        iex> pid = self()
        #PID<0.110.0>
        iex> fun = fn {:data, data, _percent} -> File.write("index.html", data)
        ...> {:error, error} -> IO.puts("error streaming file: \#{inspect(error)}")
        ...> :complete -> send pid, :complete
        ...> end
        #Function<44.97283095/1 in :erl_eval.expr/5>
        iex> NervesHubLink.Downloader.start_download("https://httpbin.com/", fun)
        {:ok, #PID<0.111.0>}
        iex> flush()
        :complete
  """
  @spec start_download(String.t() | URI.t(), event_handler_fun(), [option()]) ::
          GenServer.on_start()
  def start_download(url, fun, opts \\ [])
      when is_function(fun, 1) do
    retry_config =
      opts[:retry_config] ||
        Application.get_env(:nerves_hub_link, :retry_config, []) |> RetryConfig.validate()

    opts = Keyword.put(opts, :retry_config, retry_config)

    transport_opts =
      opts[:downloader_ssl] ||
        Application.get_env(:nerves_hub_link, :downloader_ssl, [])

    http_opts =
      opts[:downloader_http_opts] ||
        Application.get_env(:nerves_hub_link, :downloader_http_opts, [])

    opts =
      opts
      |> Keyword.put(:transport_opts, transport_opts)
      |> Keyword.put(:http_opts, http_opts)

    GenServer.start_link(__MODULE__, [URI.parse(url), fun, opts])
  end

  @impl GenServer
  def init([%URI{} = uri, fun, opts]) do
    timer = Process.send_after(self(), :max_timeout, opts[:retry_config].max_timeout)

    state =
      reset(%Downloader{
        handler_fun: fun,
        retry_args: opts[:retry_config],
        transport_opts: opts[:transport_opts],
        http_opts: opts[:http_opts],
        max_timeout: timer,
        uri: uri,
        resume_from_bytes: opts[:resume_from_bytes],
        range_end: opts[:range_end],
        label: opts[:label]
      })

    send(self(), :resume)

    {:ok, state}
  end

  @impl GenServer
  # this message is scheduled during init/1
  # it is a extreme condition where regardless of download attempts,
  # idle timeouts etc, this entire process has lived for TOO long.
  def handle_info(:max_timeout, %Downloader{} = state) do
    Logger.debug("#{log_prefix(state)} Max timeout reached")
    {:stop, :max_timeout_reached, state}
  end

  # Handle the worst case download speed timeout.
  # Please refer to `retry_config.ex` for more information on how this is calculated.
  def handle_info(:worst_case_download_speed_timeout, %Downloader{} = state) do
    Logger.debug("#{log_prefix(state)} Worst case download speed timeout reached")
    {:stop, :worst_case_download_speed_reached, state}
  end

  # a `:timeout` message is delivered by the `GenServer` after `state.retry_args.idle_timeout`
  # milliseconds have occurred. It indicates that many milliseconds have elapsed since
  # the last "chunk" from the HTTP server
  def handle_info(:timeout, %Downloader{handler_fun: handler} = state) do
    close_conn(state)
    _ = handler.({:error, :idle_timeout})
    Logger.debug("#{log_prefix(state)} Idle timeout reached")
    state = reschedule_resume(state)
    {:noreply, %{state | conn: nil}}
  end

  # if a download has been rescheduled to resume, but the maximum number of retries has been reached,
  # stop the download and return an error.
  def handle_info(
        :resume,
        %Downloader{
          retry_number: retry_number,
          retry_args: %RetryConfig{max_disconnects: retry_number}
        } = state
      ) do
    Logger.debug("#{log_prefix(state)} Max disconnects reached")
    {:stop, :max_disconnects_reached, state}
  end

  # resume a download that has been rescheduled to resume, and set the idle timeout.
  def handle_info(:resume, %Downloader{handler_fun: handler} = state) do
    case resume_download(state.uri, state) do
      {:ok, state} ->
        {:noreply, state, state.retry_args.idle_timeout}

      error ->
        _ = handler.(error)
        state = reschedule_resume(state)
        {:noreply, state}
    end
  end

  # process a streaming message from Mint
  def handle_info(message, %Downloader{conn: conn, handler_fun: handler} = state)
      when Mint.HTTP.is_connection_message(conn, message) do
    case Mint.HTTP.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, _conn, error, _responses} ->
        close_conn(state)
        _ = handler.({:error, error})
        {:noreply, reschedule_resume(%{state | conn: nil})}

      :unknown ->
        Logger.warning(
          "#{log_prefix(state)} Mint didn't recognize the message : #{inspect(message)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.warning(
      "#{log_prefix(state)} Unhandled message in `handle_info` : #{inspect(message)}"
    )

    {:noreply, state}
  end

  # schedules a message to be delivered based on retry args
  @spec reschedule_resume(t()) :: resume_rescheduled()
  defp reschedule_resume(%Downloader{retry_number: retry_number} = state) do
    # cancel the worst_case_timeout if it exists
    _ = if state.worst_case_timeout, do: Process.cancel_timer(state.worst_case_timeout)

    timer = Process.send_after(self(), :resume, state.retry_args.time_between_retries)

    %Downloader{
      state
      | request_ref: nil,
        retry_timeout: timer,
        retry_number: retry_number + 1,
        worst_case_timeout_remaining_ms: nil
    }
  end

  defp schedule_worst_case_timer(downloader) do
    # decompose here because in the formatter doesn't like all this being in the head
    %Downloader{retry_args: retry_config, content_length: content_length} = downloader
    %RetryConfig{worst_case_download_speed: speed} = retry_config
    ms = TimeoutCalculation.calculate_worst_case_timeout(content_length, speed)
    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %{downloader | worst_case_timeout: timer}
  end

  defp handle_responses([response | rest], %Downloader{} = state) do
    case handle_response(response, state) do
      # this `status != nil` thing seems really weird. Shouldn't be needed.
      %Downloader{status: status} = state when status != nil and status >= 400 ->
        {:stop, {:http_error, status}, state}

      {:error, reason, state} ->
        close_conn(state)
        _ = state.handler_fun.({:error, reason})
        {:noreply, reschedule_resume(%{state | conn: nil})}

      state ->
        handle_responses(rest, state)
    end
  end

  # when there are no more responses, and the download is marked as complete,
  # close the connection, let the handler know, and stop the process
  defp handle_responses([], %Downloader{completed: true} = state) do
    close_conn(state)
    _ = state.handler_fun.(:complete)
    {:stop, :normal, state}
  end

  # when there are no more responses, and the download isn't marked as complete,
  # wait for more responses, while also setting the idle timeout
  defp handle_responses([], %Downloader{} = state) do
    {:noreply, state, state.retry_args.idle_timeout}
  end

  @doc false
  @spec handle_response(
          {:status, reference(), non_neg_integer()} | {:headers, reference(), keyword()},
          Downloader.t()
        ) ::
          Downloader.t() | {:error, reason :: term(), Downloader.t()}
  def handle_response(
        {:status, request_ref, status},
        %Downloader{request_ref: request_ref} = state
      )
      when status >= 300 and status < 400 do
    %Downloader{state | status: status}
  end

  # the handle_responses/2 function checks this value again because this function only handles state
  def handle_response(
        {:status, request_ref, status},
        %Downloader{request_ref: request_ref} = state
      )
      when status >= 400 do
    # kind of a hack to make the error type uniform
    close_conn(state)
    state.handler_fun.({:error, %Mint.HTTPError{reason: {:http_error, status}}})
    %Downloader{state | status: status, conn: nil}
  end

  def handle_response(
        {:status, request_ref, status},
        %Downloader{request_ref: request_ref} = state
      )
      when status >= 200 and status < 300 do
    %Downloader{state | status: status}
  end

  # handles HTTP redirects.
  def handle_response(
        {:headers, request_ref, headers},
        %Downloader{request_ref: request_ref, status: status, handler_fun: handler} = state
      )
      when status >= 300 and status < 400 do
    location = URI.merge(state.uri, fetch_location(headers))
    Logger.info("#{log_prefix(state)} Redirecting to #{uri_without_query(location)}")

    state = reset(state)

    case resume_download(location, state) do
      {:ok, %Downloader{} = state} ->
        state

      error ->
        handler.(error)
        state
    end
  end

  # if we already have the content-length header, don't fetch it again.
  # range requests will change this value
  def handle_response(
        {:headers, request_ref, headers},
        %Downloader{request_ref: request_ref, content_length: content_length} = state
      )
      when content_length > 0 do
    schedule_worst_case_timer(%Downloader{state | response_headers: headers})
  end

  def handle_response(
        {:headers, request_ref, headers},
        %Downloader{request_ref: request_ref, content_length: 0} = state
      ) do
    case fetch_accept_ranges(headers) do
      accept_ranges when accept_ranges in ["none", nil] ->
        Logger.error("#{log_prefix(state)} HTTP Server does not support the Range header")

      _ ->
        :ok
    end

    content_length = fetch_content_length(headers)

    schedule_worst_case_timer(%Downloader{
      state
      | response_headers: headers,
        content_length: content_length
    })
  end

  def handle_response(
        {:data, request_ref, data},
        %Downloader{
          request_ref: request_ref,
          resume_from_bytes: resume_from_bytes,
          downloaded_length: downloaded,
          content_length: content_length
        } = state
      ) do
    downloaded_length = downloaded + byte_size(data)

    resume_from_bytes = resume_from_bytes || 0
    percent = (downloaded + resume_from_bytes) / (content_length + resume_from_bytes) * 100

    case state.handler_fun.({:data, data, Float.round(percent, 2)}) do
      :ok -> %Downloader{state | downloaded_length: downloaded_length}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Mark the download as completed when downloaded_length matches content_length.
  def handle_response(
        {:done, request_ref},
        %Downloader{
          request_ref: request_ref,
          content_length: total,
          downloaded_length: total
        } = state
      ) do
    Logger.debug(
      "#{log_prefix(state)} Download completed (downloaded_length and content_length match: #{total})"
    )

    %{state | completed: true}
  end

  # While not expected, it has been observed that downloaded_length may be greater than content_length.
  # I'm unsure why this happens, and if this is a bug with the Downloader or something happening on the other end.
  # This function signature handles the case where downloaded_length is greater than content_length and marks the
  # download as completed, leaving the cleanup to the caller.
  def handle_response(
        {:done, request_ref},
        %Downloader{
          request_ref: request_ref,
          content_length: content_length,
          downloaded_length: downloaded_length
        } = state
      )
      when downloaded_length > content_length do
    Logger.warning(
      "#{log_prefix(state)} Download completed, but downloaded length is greater than content length (downloaded_length: #{downloaded_length} | content_length: #{content_length})"
    )

    %{state | completed: true}
  end

  # Its possible for the underlying tcp/ssl connection to be closed before the download is complete.
  # https://github.com/elixir-mint/mint/blob/0bfcc869b53b83989c24ba681d66d0a447b5a1c3/lib/mint/http1.ex#L488-L491
  #
  # If that happens, Mint will send a `{:done, request_ref}` but the body may not be fully received.
  # https://github.com/elixir-mint/mint/blob/0bfcc869b53b83989c24ba681d66d0a447b5a1c3/lib/mint/http1.ex#L524
  def handle_response({:done, request_ref}, %Downloader{request_ref: request_ref} = state) do
    Logger.warning(
      "#{log_prefix(state)} Download completed, but content length and download length mismatch detected (downloaded_length: #{state.downloaded_length} | content_length: #{state.content_length})"
    )

    {:error, :downloaded_content_length_mismatch, state}
  end

  # ignore other messages when redirecting
  def handle_response(_, %Downloader{status: nil} = state) do
    state
  end

  defp reset(%Downloader{} = state) do
    %Downloader{
      state
      | retry_number: 0,
        downloaded_length: 0,
        content_length: 0
    }
  end

  @spec resume_download(URI.t(), t()) ::
          {:ok, initialized_download()}
          | {:error, Mint.Types.error()}
          | {:error, Mint.HTTP.t(), Mint.Types.error()}
  defp resume_download(
         %URI{scheme: scheme, host: host, port: port, path: path, query: query} = uri,
         %Downloader{transport_opts: transport_opts, http_opts: http_opts} = state
       )
       when scheme in ["https", "http"] do
    request_headers =
      [{"content-type", "application/octet-stream"}]
      |> add_range_header(state)
      |> add_retry_number_header(state)
      |> add_user_agent_header(state)

    # mint doesn't accept the query as the http body, so it must be encoded
    # like this. There may be a better way to do this..
    path = if query, do: "#{path}?#{query}", else: path

    if state.retry_number > 0 do
      Logger.info(
        "#{log_prefix(state)} Resuming download attempt number #{state.retry_number} #{uri_without_query(uri)}"
      )
    end

    close_conn(state)

    connect_opts = merge_http_opts([transport_opts: transport_opts], http_opts)

    with {:ok, conn} <-
           Mint.HTTP.connect(String.to_existing_atom(scheme), host, port, connect_opts),
         {:ok, conn, request_ref} <- Mint.HTTP.request(conn, "GET", path, request_headers, nil),
         :ok <- report_download_started(conn) do
      {:ok,
       %Downloader{
         state
         | uri: uri,
           conn: conn,
           request_ref: request_ref,
           status: nil,
           response_headers: []
       }}
    end
  end

  @spec fetch_content_length(Mint.Types.headers()) :: 0 | pos_integer()
  defp fetch_content_length(headers)
  defp fetch_content_length([{"content-length", value} | _]), do: String.to_integer(value)
  defp fetch_content_length([_ | rest]), do: fetch_content_length(rest)
  defp fetch_content_length([]), do: 0

  @spec fetch_location(Mint.Types.headers()) :: nil | URI.t()
  defp fetch_location(headers)
  defp fetch_location([{"location", uri} | _]), do: URI.parse(uri)
  defp fetch_location([_ | rest]), do: fetch_location(rest)
  defp fetch_location([]), do: nil

  defp fetch_accept_ranges(headers)
  defp fetch_accept_ranges([{"accept-ranges", value} | _]), do: value
  defp fetch_accept_ranges([_ | rest]), do: fetch_accept_ranges(rest)
  defp fetch_accept_ranges([]), do: nil

  @spec add_range_header(Mint.Types.headers(), t()) :: Mint.Types.headers()
  defp add_range_header(headers, state)

  # Only part of the file was asked for, so where it ends is already known and
  # doesn't depend on what the server says.
  defp add_range_header(headers, %Downloader{range_end: range_end} = state)
       when is_integer(range_end) do
    [{"Range", "bytes=#{next_byte(state)}-#{range_end}"} | headers]
  end

  # No response has been seen yet, so the total size of the file isn't known and
  # the request is left open ended.
  defp add_range_header(headers, %Downloader{content_length: 0} = state) do
    case next_byte(state) do
      0 -> headers
      offset -> [{"Range", "bytes=#{offset}-"} | headers]
    end
  end

  defp add_range_header(headers, %Downloader{content_length: content_length} = state) do
    [{"Range", "bytes=#{next_byte(state)}-#{resume_from(state) + content_length}"} | headers]
  end

  # `downloaded_length` and `content_length` only count the part of the file
  # this download is responsible for, so both have to be shifted back by
  # `resume_from_bytes` to become offsets into the file being downloaded.
  # Without that, a download resumed from a partial file would ask for the wrong
  # range after a disconnect and silently stitch together the wrong bytes.
  @spec next_byte(t()) :: non_neg_integer()
  defp next_byte(%Downloader{downloaded_length: downloaded_length} = state) do
    resume_from(state) + downloaded_length
  end

  @spec resume_from(t()) :: non_neg_integer()
  defp resume_from(%Downloader{resume_from_bytes: nil}), do: 0
  defp resume_from(%Downloader{resume_from_bytes: resume_from_bytes}), do: resume_from_bytes

  @spec add_retry_number_header(Mint.Types.headers(), t()) :: Mint.Types.headers()
  defp add_retry_number_header(headers, %Downloader{retry_number: retry_number}),
    do: [{"X-Retry-Number", "#{retry_number}"} | headers]

  defp add_user_agent_header(headers, _),
    do: [{"User-Agent", "NHL/#{Application.spec(:nerves_hub_link)[:vsn]}"} | headers]

  # OTP writes the whole state to the crash report when this process stops
  # abnormally, which for a download means the signed firmware URL and whatever
  # was configured as SSL options - including a private key. `format_status/1`
  # takes those out while leaving the rest, which is what makes the report worth
  # reading, alone.
  #
  # OTP has called `format_status/1` since 25, so every supported release uses
  # it, but `GenServer` only started declaring it as a callback in Elixir 1.17.
  # Annotating it before that warns that the callback is unknown, and leaving
  # the annotation off after it warns that it is missing.
  if Version.match?(System.version(), ">= 1.17.0") do
    @impl GenServer
  end

  @spec format_status(map()) :: map()
  def format_status(%{state: state} = status), do: %{status | state: redact(state)}
  def format_status(status), do: status

  # SSL and HTTP options are passed through to Mint, so what is in them is up to
  # whoever configured them. These are the keys that hold a secret.
  @redacted_opts [:key, :password, :proxy_headers]

  @spec redact(t() | term()) :: t() | term()
  defp redact(%Downloader{} = state) do
    %Downloader{
      state
      | uri: redact_uri(state.uri),
        transport_opts: redact_opts(state.transport_opts),
        http_opts: redact_opts(state.http_opts)
    }
  end

  defp redact(state), do: state

  defp redact_uri(%URI{query: nil} = uri), do: uri
  defp redact_uri(%URI{} = uri), do: %URI{uri | query: "[REDACTED]"}
  defp redact_uri(uri), do: uri

  defp redact_opts(opts) when is_list(opts) do
    Enum.map(opts, fn
      {key, _value} when key in @redacted_opts -> {key, "[REDACTED]"}
      {key, value} when is_list(value) -> {key, redact_opts(value)}
      other -> other
    end)
  end

  defp redact_opts(opts), do: opts

  # A label tells apart the log lines of downloads running at the same time,
  # which are otherwise indistinguishable.
  @spec log_prefix(t()) :: String.t()
  defp log_prefix(%Downloader{label: nil}), do: "[NervesHubLink.Downloader]"
  defp log_prefix(%Downloader{label: label}), do: "[NervesHubLink.Downloader #{label}]"

  # Firmware URLs are signed, so the query string is a credential and has no
  # business being written to the log.
  @spec uri_without_query(URI.t()) :: String.t()
  defp uri_without_query(uri) do
    uri
    |> URI.to_string()
    |> String.replace(~r/\?.*/, "?...")
  end

  defp close_conn(%Downloader{conn: nil}), do: :ok

  defp close_conn(%Downloader{conn: conn}) do
    {:ok, _} = Mint.HTTP.close(conn)
    :ok
  end

  defp report_download_started(conn) do
    downloader_network_interface = NetworkInterface.from_socket(Mint.HTTP.get_socket(conn))
    NervesHubLink.send_update_status({:started, downloader_network_interface})
  end

  # Shallow-merge user-supplied opts on top of the base, but for :transport_opts
  # specifically merge the nested keyword list so callers who only want to add
  # e.g. a :timeout don't accidentally clobber our SSL config.
  @doc false
  @spec merge_http_opts(keyword(), keyword()) :: keyword()
  def merge_http_opts(base, user_opts) do
    Keyword.merge(base, user_opts, fn
      :transport_opts, base_v, user_v -> Keyword.merge(base_v, user_v)
      _key, _base_v, user_v -> user_v
    end)
  end
end
