# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2025 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Downloader.UrlToFile do
  @moduledoc """
  Handles downloading files via HTTP with persistent storage.
  """

  use GenServer

  alias NervesHubLink.Downloader.RetryConfig
  alias NervesHubLink.Downloader.UrlToFile

  require Logger

  defstruct uri: nil,
            uuid: nil,
            content_length: 0,
            downloaded_length: 0,
            ref: nil,
            task: nil,
            io: nil,
            time: 0,
            start_time: 0,
            handler_fun: nil,
            retry_number: 0,
            retry_without_progress: 0,
            retry_args: nil,
            max_timeout: nil,
            retry_timeout: nil,
            worst_case_timeout: nil,
            worst_case_timeout_remaining_ms: nil

  @type handler_event ::
          {:complete, filepath :: String.t()}
          | {:reauth, download_length_bytes :: non_neg_integer(),
             time_taken_ms :: non_neg_integer()}
          | {:download_progress, percentage :: non_neg_integer()}
          | {:error,
             :unexpected_redirect
             | :idle_timeout
             | :request_error
             | {:http_error, status_code :: non_neg_integer()}}
  @type event_handler_fun :: (handler_event -> any())
  @type retry_args :: RetryConfig.t()

  # alias for readability
  @typep timer() :: reference()

  @type t :: %UrlToFile{
          uri: nil | URI.t(),
          uuid: nil | String.t(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          ref: nil | integer(),
          task: Task.t(),
          io: File.io_device(),
          time: integer(),
          start_time: integer(),
          handler_fun: event_handler_fun,
          retry_number: non_neg_integer(),
          retry_without_progress: non_neg_integer(),
          retry_args: retry_args(),
          max_timeout: timer(),
          retry_timeout: nil | timer(),
          worst_case_timeout: nil | timer(),
          worst_case_timeout_remaining_ms: nil | non_neg_integer()
        }

  @type initialized_download :: %UrlToFile{
          uri: URI.t(),
          uuid: String.t(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          task: Task.t(),
          ref: integer(),
          io: File.io_device(),
          time: integer(),
          start_time: integer(),
          handler_fun: event_handler_fun,
          retry_number: non_neg_integer(),
          retry_without_progress: non_neg_integer()
        }

  # todo, this should be `t`, but with retry_timeout
  @type resume_rescheduled :: t()

  @doc """
  Begins downloading a file at `url` handled by `fun`.
  """
  @spec start_download(String.t(), String.t() | URI.t(), event_handler_fun()) ::
          GenServer.on_start()
  def start_download(uuid, url, fun) when is_function(fun, 1) do
    retry_config =
      Application.get_env(:nerves_hub_link, :retry_config, [])
      |> RetryConfig.validate()

    GenServer.start_link(__MODULE__, [uuid, URI.parse(url), fun, retry_config])
  end

  @spec start_download(String.t(), String.t() | URI.t(), event_handler_fun(), RetryConfig.t()) ::
          GenServer.on_start()
  def start_download(uuid, url, fun, %RetryConfig{} = retry_args) when is_function(fun, 1) do
    GenServer.start_link(__MODULE__, [uuid, URI.parse(url), fun, retry_args])
  end

  @impl GenServer
  def init([uuid, %URI{} = uri, fun, %RetryConfig{} = retry_args]) do
    timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)

    state = %UrlToFile{
      retry_args: retry_args,
      max_timeout: timer,
      uri: uri,
      uuid: uuid,
      handler_fun: fun
    }

    case check_disk() do
      :ok ->
        send(self(), :resume)
        {:ok, state}

      :error ->
        # Gentle exit, it will be handled
        Process.flag(:trap_exit, true)
        {:stop, :disk_error}
    end
  end

  defp handle_chunk(pid, ref, {:data, data}, {req, res}) do
    # This uses a call to be able to apply backpressure which should propagate
    # into Req not producing more chunks
    # This would imply the storage medium is struggling significantly
    GenServer.call(pid, {:chunk, ref, data, req, res}, 60_000)
  end

  @impl GenServer
  def handle_call(
        {:chunk, chunk_ref, data, request, response},
        _from,
        %{io: io, ref: ref} =
          state
      )
      when chunk_ref == ref do
    state =
      if response.status < 300 do
        IO.binwrite(io, data)
        # Performs state updates and reporting progress
        update_progress(state, byte_size(data), response)
      else
        # Do not write data on redirect chunks
        state
      end

    {:reply, {:cont, {request, response}}, state}
  end

  def handle_call({:chunk, _ref, _, req, res}, _from, state) do
    Logger.warning(
      "[NervesHubLink] Received chunk from other Task than the current one. Asking it to halt."
    )

    {:reply, {:halt, {req, res}}, state}
  end

  @impl GenServer
  # this message is scheduled during init/1
  # it is a extreme condition where regardless of download attempts,
  # idle timeouts etc, this entire process has lived for TOO long.
  def handle_info(:max_timeout, %UrlToFile{} = state) do
    _ = state.handler_fun.({:error, :max_timeout_reached})
    {:stop, :max_timeout_reached, state}
  end

  # this message is scheduled when we receive the `content_length` value
  def handle_info(:worst_case_download_speed_timeout, %UrlToFile{} = state) do
    {:stop, :worst_case_download_speed_reached, state}
  end

  # message is scheduled when a resumable event happens.
  def handle_info(
        :resume,
        %UrlToFile{
          retry_without_progress: retry_number,
          retry_args: %RetryConfig{max_disconnects: retry_number}
        } = state
      ) do
    {:stop, :max_disconnects_reached, state}
  end

  def handle_info(:resume, %UrlToFile{} = state) do
    case setup_io_device(state) do
      {:ok, state} ->
        {:ok, state} = resume_download(state)
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info({return_ref, result}, %{task: %{ref: ref}} = state) when return_ref == ref do
    # The task succeed so we can demonitor its reference
    Process.demonitor(return_ref, [:flush])
    handle_result(result, state)
  end

  def handle_info({ref, _result}, state) do
    Logger.info("[NervesHubLink] A download task we were no longer using completed.")
    # The task succeed so we can demonitor its reference
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, return_ref, _, _pid, reason}, %{task: %{ref: ref}} = state)
      when return_ref == ref do
    Logger.error("[NervesHubLink] Download task failed with reason: #{inspect(reason)}")
    {:stop, :task_failed, state}
  end

  def handle_info({:DOWN, _ref, _, _pid, reason}, state) do
    Logger.info("[NervesHubLink] Old task failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warning(
      "[NervesHubLink] Unexpected message in UrlToFile download: #{inspect(message)}"
    )

    {:noreply, state}
  end

  defp handle_result({:ok, %{status: status}}, state) when status >= 200 and status < 300 do
    Logger.info("[NervesHubLink] Downloaded completed...")
    retry_if_not_complete(state)
  end

  defp handle_result({:ok, %{status: status}}, state) when status >= 300 and status < 400 do
    # Unexpected because Req handles redirects
    Logger.warning("[NervesHubLink] Unexpected redirect result in download.")
    _ = state.handler_fun.({:error, :unexpected_redirect})
    retry_if_not_complete(state)
  end

  defp handle_result({:ok, %{status: 403}}, state) do
    url = URI.to_string(state.uri)
    Logger.error("[NervesHubLink] Download failed for #{url} with 403. Must re-auth.")
    time_taken = System.monotonic_time(:millisecond) - state.time
    _ = state.handler_fun.({:reauth, state.downloaded_length, time_taken})
    {:stop, {:http_error, 403}, state}
  end

  defp handle_result({:ok, %{status: status}}, state) when status > 400 do
    url = URI.to_string(state.uri)
    Logger.error("[NervesHubLink] Download failed for #{url} with error status:\n#{status}")
    _ = state.handler_fun.({:error, {:http_error, status}})
    {:stop, {:http_error, status}, state}
  end

  defp handle_result({:error, %Req.TransportError{reason: :timeout}}, state) do
    url = URI.to_string(state.uri)
    Logger.warning("[NervesHubLink] Download failed for #{url} idle timeout.")
    Logger.info("[NervesHubLink] Retrying download as retry no #{state.retry_number}.")
    _ = state.handler_fun.({:error, :idle_timeout})
    retry_if_not_complete(state)
  end

  defp handle_result({:error, exception}, state) do
    url = URI.to_string(state.uri)

    Logger.warning(
      "[NervesHubLink] Download failed for #{url} with error:\n#{inspect(exception)}"
    )

    _ = state.handler_fun.({:error, :request_error})

    retry_if_not_complete(state)
  end

  defp retry_if_not_complete(%{downloaded_length: downloaded, content_length: total} = state)
       when total > 0 and downloaded == total do
    _ = state.handler_fun.({:complete, path(state.uuid)})
    {:stop, :normal, state}
  end

  defp retry_if_not_complete(
         %{
           retry_without_progress: retries,
           retry_args: %{max_disconnects: max_disconnects}
         } = state
       )
       when retries <= max_disconnects do
    Logger.info("[NervesHubLink] Retrying download as retry no #{state.retry_number}.")
    {:noreply, reschedule_resume(state)}
  end

  defp retry_if_not_complete(state) do
    Logger.error(
      "[NervesHubLink] Exhausted #{state.retry_args.max_disconnects} retries. Reporting error and stopping downloader."
    )

    {:stop, :max_disconnects_reached, state}
  end

  # schedules a message to be delivered based on retry args
  @spec reschedule_resume(t()) :: resume_rescheduled()
  defp reschedule_resume(%UrlToFile{retry_number: retry_number} = state) do
    # cancel the worst_case_timeout if it was running
    worst_case_timeout_remaining_ms =
      if state.worst_case_timeout do
        Process.cancel_timer(state.worst_case_timeout) || nil
      end

    timer = Process.send_after(self(), :resume, state.retry_args.time_between_retries)

    %UrlToFile{
      state
      | retry_timeout: timer,
        retry_number: retry_number + 1,
        retry_without_progress: state.retry_without_progress + 1,
        worst_case_timeout_remaining_ms: worst_case_timeout_remaining_ms
    }
  end

  @spec resume_download(t()) :: {:ok, initialized_download()}
  defp resume_download(%UrlToFile{} = state) do
    Logger.info(
      "[NervesHubLink] Resuming download attempt number #{state.retry_without_progress} (total #{state.retry_number}) for #{state.uri}"
    )

    pid = self()
    ref = System.unique_integer()
    # Accuracy is not very important for this time, we just estimate throughput using it
    time = System.monotonic_time(:millisecond)

    range =
      if state.content_length > 0 do
        "#{state.downloaded_length}-#{state.content_length}"
      else
        "#{state.downloaded_length}-"
      end

    Logger.info("Resuming from #{state.downloaded_length}, range #{range}")

    t =
      Task.Supervisor.async_nolink(NervesHubLink.TaskSupervisor, fn ->
        res =
          Req.get(URI.to_string(state.uri),
            into: &handle_chunk(pid, ref, &1, &2),
            # Using a range header without known total, is simpler
            range: "bytes=#{range}",
            headers: [
              content_type: "application/octet-stream",
              x_retry_number: to_string(state.retry_without_progress),
              user_agent: "NHL/#{Application.spec(:nerves_hub_link)[:vsn]}"
            ],
            # Note: We don't use Req's built-in retries because they don't support
            #       resuming our downloads where we left off.
            max_retries: 0,
            receive_timeout: state.retry_args.idle_timeout
          )

        res
      end)

    {:ok,
     %{
       state
       | uri: state.uri,
         task: t,
         ref: ref,
         time: time,
         start_time: time
     }}
  end

  @doc """
  Generate the storage path for a firmware download.
  """
  @spec path(uuid :: String.t()) :: String.t()
  def path(uuid) do
    base_path =
      Application.get_env(:nerves_hub_link, :persist_dir, "/data/nerves_hub_link/firmware")

    Path.join(base_path, "#{uuid}.fw")
  end

  defp check_disk() do
    firmware_path = path("test")

    _ =
      firmware_path
      |> Path.dirname()
      |> File.mkdir_p()

    case File.write(firmware_path, "test-data") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[NervesHubLink] Failed to write to disk #{firmware_path} with #{inspect(reason)}. Will not use persisted download method."
        )

        :error
    end
  end

  @spec setup_io_device(t()) ::
          {:ok, t()} | {:error, {:disk_failure, any()}}
  defp setup_io_device(%UrlToFile{uuid: uuid} = state) do
    :ok = remove_old_persisted_firmwares(uuid)
    firmware_path = path(uuid)

    case File.stat(firmware_path) do
      # does not exist, start fresh
      {:error, :enoent} ->
        open_path(firmware_path, 0, state)

      {:ok, %{type: :regular, size: size}} ->
        open_path(firmware_path, size, state)

      {:error, reason} ->
        Logger.error(
          "[NervesHubLink] Failed to retrieve firmware file stats on disk at #{firmware_path} with: #{inspect(reason)}."
        )

        {:error, {:disk_failure, reason}}
    end
  end

  @spec remove_old_persisted_firmwares(String.t()) :: :ok
  defp remove_old_persisted_firmwares(uuid) do
    base_path =
      Application.get_env(:nerves_hub_link, :persist_dir, "/data/nerves_hub_link/firmware")

    Path.join(base_path, "**.fw")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, uuid))
    |> Enum.each(fn filepath ->
      Logger.info("[NervesHubLink] Removing old firmware: #{filepath}")
      File.rm(filepath)
    end)
  end

  @spec open_path(String.t(), non_neg_integer(), t()) ::
          {:ok, t()} | {:error, {:disk_failure, any()}}
  defp open_path(firmware_path, size, state) do
    with :ok <- File.mkdir_p(Path.dirname(firmware_path)),
         {:ok, io} <- File.open(firmware_path, [:binary, :append]) do
      Logger.info(
        "[NervesHubLink] Starting firmware download from #{size} bytes at #{firmware_path}"
      )

      {:ok, %{state | downloaded_length: size, io: io}}
    else
      {:error, reason} ->
        Logger.error(
          "[NervesHubLink] Failed to create firmware file on disk #{firmware_path} with #{inspect(reason)}. Download failed."
        )

        {:error, {:disk_failure, reason}}
    end
  end

  defp update_progress(
         %{
           downloaded_length: downloaded_length,
           content_length: content_length
         } = state,
         chunk_size,
         response
       ) do
    new_size = downloaded_length + chunk_size

    # Set content length if not already set
    total_size =
      with 0 <- content_length,
           [value] <- Req.Response.get_header(response, "content-length"),
           {length, _} <- Integer.parse(value) do
        length
      else
        _ ->
          content_length
      end

    old_mb = round(downloaded_length / 1024 / 1024)
    new_mb = round(new_size / 1024 / 1024)

    # Report first chunk, final chunk and any increase in MB
    state =
      if (downloaded_length == 0 and new_size > 0) or
           (total_size > 0 and downloaded_length == total_size) or
           new_mb > old_mb do
        t = System.monotonic_time(:millisecond)
        bytes_per_second = downloaded_length / max((t - state.start_time) / 1000, 1)

        # If size is known we also report the percentage
        if total_size > 0 do
          new_percent = round(new_size / total_size * 100)
          _ = state.handler_fun.({:download_progress, new_percent})

          Logger.info(
            "[NervesHubLink] Download progress for #{state.uuid}: #{new_percent}% [#{new_mb}MB] @ #{pretty_speed(bytes_per_second)}"
          )
        else
          Logger.info(
            "[NervesHubLink] Download progress for #{state.uuid}: #{new_mb}MB @ #{pretty_speed(bytes_per_second)}"
          )
        end

        %{state | time: t}
      else
        state
      end

    %{
      state
      | downloaded_length: new_size,
        content_length: total_size,
        retry_without_progress: 0
    }
  end

  defp pretty_speed(bps, scale \\ 0)

  defp pretty_speed(bps, scale) when bps > 1024 do
    pretty_speed(bps / 1024, scale + 1)
  end

  @units %{
    0 => "bytes/s",
    1 => "KB/s",
    2 => "MB/s",
    3 => "GB/s",
    4 => "TB/s"
  }
  defp pretty_speed(bps, scale) do
    "#{Float.round(bps, 1)}#{Map.get(@units, scale, "???/s")}"
  end
end
