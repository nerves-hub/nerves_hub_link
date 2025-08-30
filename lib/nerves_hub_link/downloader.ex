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

  require Logger
  require Mint.HTTP

  defstruct uri: nil,
            conn: nil,
            request_ref: nil,
            status: nil,
            response_headers: [],
            content_length: 0,
            downloaded_length: 0,
            retry_number: 0,
            handler_fun: nil,
            retry_args: nil,
            max_timeout: nil,
            retry_timeout: nil,
            worst_case_timeout: nil,
            worst_case_timeout_remaining_ms: nil

  @type handler_event :: {:data, binary()} | {:error, any()} | :complete
  @type event_handler_fun :: (handler_event -> any())
  @type retry_args :: RetryConfig.t()

  # alias for readability
  @typep timer() :: reference()

  @type t :: %Downloader{
          uri: nil | URI.t(),
          conn: nil | Mint.HTTP.t(),
          request_ref: nil | reference(),
          status: nil | Mint.Types.status(),
          response_headers: Mint.Types.headers(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          retry_number: non_neg_integer(),
          handler_fun: event_handler_fun,
          retry_args: retry_args(),
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

  @doc """
  Begins downloading a file at `url` handled by `fun`.

  # Example

        iex> pid = self()
        #PID<0.110.0>
        iex> fun = fn {:data, data} -> File.write("index.html", data)
        ...> {:error, error} -> IO.puts("error streaming file: \#{inspect(error)}")
        ...> :complete -> send pid, :complete
        ...> end
        #Function<44.97283095/1 in :erl_eval.expr/5>
        iex> NervesHubLink.Downloader.start_download("https://httpbin.com/", fun)
        {:ok, #PID<0.111.0>}
        iex> flush()
        :complete
  """
  @spec start_download(String.t() | URI.t(), event_handler_fun()) :: GenServer.on_start()
  def start_download(url, fun) when is_function(fun, 1) do
    retry_config =
      Application.get_env(:nerves_hub_link, :retry_config, [])
      |> RetryConfig.validate()

    GenServer.start_link(__MODULE__, [URI.parse(url), fun, retry_config])
  end

  @spec start_download(String.t() | URI.t(), event_handler_fun(), RetryConfig.t()) ::
          GenServer.on_start()
  def start_download(url, fun, %RetryConfig{} = retry_args) when is_function(fun, 1) do
    GenServer.start_link(__MODULE__, [URI.parse(url), fun, retry_args])
  end

  @impl GenServer
  def init([%URI{} = uri, fun, %RetryConfig{} = retry_args]) do
    timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)

    state =
      reset(%Downloader{
        handler_fun: fun,
        retry_args: retry_args,
        max_timeout: timer,
        uri: uri
      })

    send(self(), :resume)
    {:ok, state}
  end

  @impl GenServer
  # this message is scheduled during init/1
  # it is a extreme condition where regardless of download attempts,
  # idle timeouts etc, this entire process has lived for TOO long.
  def handle_info(:max_timeout, %Downloader{} = state) do
    {:stop, :max_timeout_reached, state}
  end

  # this message is scheduled when we receive the `content_length` value
  def handle_info(:worst_case_download_speed_timeout, %Downloader{} = state) do
    {:stop, :worst_case_download_speed_reached, state}
  end

  # this message is delivered after `state.retry_args.idle_timeout`
  # milliseconds have occurred. It indicates that many milliseconds have elapsed since
  # the last "chunk" from the HTTP server
  def handle_info(:timeout, %Downloader{handler_fun: handler} = state) do
    _ = handler.({:error, :idle_timeout})
    state = reschedule_resume(state)
    {:noreply, state}
  end

  # message is scheduled when a resumable event happens.
  def handle_info(
        :resume,
        %Downloader{
          retry_number: retry_number,
          retry_args: %RetryConfig{max_disconnects: retry_number}
        } = state
      ) do
    {:stop, :max_disconnects_reached, state}
  end

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

  def handle_info(message, %Downloader{conn: conn, handler_fun: handler} = state)
      when Mint.HTTP.is_connection_message(conn, message) do
    case Mint.HTTP.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, error, responses} ->
        _ = handler.({:error, error})
        handle_responses(responses, reschedule_resume(%{state | conn: conn}))

      :unknown ->
        Logger.warning(
          "[NervesHubLink.Downloader] Mint didn't recognize the message : #{inspect(message)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.warning(
      "[NervesHubLink.Downloader] Unhandled message in `handle_info` : #{inspect(message)}"
    )

    {:noreply, state}
  end

  # schedules a message to be delivered based on retry args
  @spec reschedule_resume(t()) :: resume_rescheduled()
  defp reschedule_resume(%Downloader{retry_number: retry_number} = state) do
    # cancel the worst_case_timeout if it was running
    worst_case_timeout_remaining_ms =
      if state.worst_case_timeout do
        Process.cancel_timer(state.worst_case_timeout) || nil
      end

    timer = Process.send_after(self(), :resume, state.retry_args.time_between_retries)

    %Downloader{
      state
      | retry_timeout: timer,
        retry_number: retry_number + 1,
        worst_case_timeout_remaining_ms: worst_case_timeout_remaining_ms
    }
  end

  @spec schedule_worst_case_timer(t()) :: t()
  # only calculate worst_case_timeout_remaining_ms is not set
  defp schedule_worst_case_timer(%Downloader{worst_case_timeout_remaining_ms: nil} = downloader) do
    # decompose here because in the formatter doesn't like all this being in the head
    %Downloader{retry_args: retry_config, content_length: content_length} = downloader
    %RetryConfig{worst_case_download_speed: speed} = retry_config
    ms = TimeoutCalculation.calculate_worst_case_timeout(content_length, speed)
    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %Downloader{downloader | worst_case_timeout: timer}
  end

  # worst_case_timeout_remaining_ms gets set if the timer gets canceled by reschedule_resume/1
  # this is done so that the timer doesn't keep counting while not actively downloading data
  defp schedule_worst_case_timer(%Downloader{worst_case_timeout_remaining_ms: ms} = downloader) do
    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %Downloader{downloader | worst_case_timeout: timer}
  end

  defp handle_responses([response | rest], %Downloader{} = state) do
    case handle_response(response, state) do
      # this `status != nil` thing seems really weird. Shouldn't be needed.
      %Downloader{status: status} = state when status != nil and status >= 400 ->
        {:stop, {:http_error, status}, state}

      state ->
        handle_responses(rest, state)
    end
  end

  defp handle_responses(
         [],
         %Downloader{downloaded_length: downloaded, content_length: downloaded} = state
       )
       when downloaded != 0 do
    _ = state.handler_fun.(:complete)
    {:stop, :normal, state}
  end

  defp handle_responses([], %Downloader{} = state) do
    {:noreply, state, state.retry_args.idle_timeout}
  end

  @doc false
  @spec handle_response(
          {:status, reference(), non_neg_integer()} | {:headers, reference(), keyword()},
          Downloader.t()
        ) ::
          Downloader.t()
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
    state.handler_fun.({:error, %Mint.HTTPError{reason: {:http_error, status}}})
    %Downloader{state | status: status}
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
    location = fetch_location(headers)
    Logger.info("[NervesHubLink] Redirecting to #{location}")

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
        Logger.error("[NervesHubLink] HTTP Server does not support the Range header")

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
        %Downloader{request_ref: request_ref, downloaded_length: downloaded} = state
      ) do
    _ = state.handler_fun.({:data, data})
    %Downloader{state | downloaded_length: downloaded + byte_size(data)}
  end

  def handle_response({:done, request_ref}, %Downloader{request_ref: request_ref} = state) do
    state
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
         %Downloader{} = state
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
      Logger.info("[NervesHubLink] Resuming download attempt number #{state.retry_number} #{uri}")
    end

    with {:ok, conn} <- Mint.HTTP.connect(String.to_existing_atom(scheme), host, port),
         {:ok, conn, request_ref} <- Mint.HTTP.request(conn, "GET", path, request_headers, nil) do
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

  defp add_range_header(headers, %Downloader{content_length: 0}), do: headers

  defp add_range_header(headers, %Downloader{downloaded_length: r, content_length: total})
       when total > 0,
       do: [{"Range", "bytes=#{r}-#{total}"} | headers]

  @spec add_retry_number_header(Mint.Types.headers(), t()) :: Mint.Types.headers()
  defp add_retry_number_header(headers, %Downloader{retry_number: retry_number}),
    do: [{"X-Retry-Number", "#{retry_number}"} | headers]

  defp add_user_agent_header(headers, _),
    do: [{"User-Agent", "NHL/#{Application.spec(:nerves_hub_link)[:vsn]}"} | headers]
end
