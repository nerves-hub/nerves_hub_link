# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.PartsUpdater do
  @moduledoc """
  Downloads firmware to disk one part at a time, checking each part against the
  checksums NervesHub sends in the update payload before it is used.

  Like `NervesHubLink.UpdateManager.CachingUpdater` this keeps the download on
  disk so an interrupted update doesn't have to start again from the beginning.
  The difference is what "where did I get to" means. `CachingUpdater` trusts the
  size of the partial file, so a part that was being written when the power went
  out, or that arrived corrupted, is silently treated as good and only shows up
  much later as an `fwup` error. Here each part is hashed as it arrives and
  compared to the checksum for that part:

    * a part that fails is thrown away and downloaded again, without discarding
      the parts before it
    * a part that has already been downloaded and verified is not downloaded
      again after a restart
    * the firmware handed to `fwup` is known to match what NervesHub sent

  Once every part has been verified the parts are streamed into `fwup` in order,
  so the whole firmware never needs to exist on disk twice. The parts are left
  where they are afterwards, and are removed when a different firmware starts
  downloading, so an update that is applied but doesn't stick doesn't have to be
  downloaded again.

  To use this strategy, configure NervesHubLink with:

      config :nerves_hub_link,
        updater: NervesHubLink.UpdateManager.PartsUpdater

  ## Configuration

      config :nerves_hub_link, NervesHubLink.UpdateManager.PartsUpdater,
        cache_dir: "/data/nerves_hub_link/firmware",
        part_size: 1_048_576,
        max_part_attempts: 3,
        max_concurrent_parts: 1

    * `:cache_dir` - where downloads are kept. Each firmware gets its own
      directory underneath, named after its UUID. This directory belongs to
      `NervesHubLink`, which removes anything in it that isn't part of the
      firmware being downloaded, so don't point it at somewhere shared.
      Defaults to `/data/nerves_hub_link/firmware`.

    * `:part_size` - the number of bytes covered by each checksum. This has to
      match the size NervesHub used when it hashed the firmware, which is 1 MiB.
      A value that would split the firmware into a different number of parts
      than the payload has checksums for is rejected, but one that happens to
      produce the same count is not, and shows up as every part failing
      verification. Defaults to `1_048_576`.

    * `:max_part_attempts` - how many times a single part may fail verification
      before the update is failed. Defaults to `3`.

    * `:max_concurrent_parts` - how many downloads may run at once. See below.
      Defaults to `1`.

  ## Downloading more than one part at a time

  With `:max_concurrent_parts` set above `1`, the parts still needed are divided
  into that many contiguous ranges and each range is downloaded by its own
  connection. Parts are still verified as they arrive and are still applied in
  order once they are all present, so nothing about the result changes - only
  how many connections are open while it happens.

  This is worth doing on links where a single connection can't fill the
  available bandwidth, such as high latency satellite or cellular. It costs a
  connection per range on both the device and whatever is serving the firmware,
  which is multiplied by every device in a deployment, so raise it deliberately
  rather than by default. Each connection also reports a `:started` update
  status of its own, so NervesHub sees one per range.

  Each download labels its log lines with the parts it is fetching, so the log
  can still be followed when several are running.

  ## Older NervesHub servers

  `partials_checksums` is only sent by newer NervesHub servers. When it is
  missing the firmware is downloaded as a single part and verified against the
  whole file `checksum` if one was sent, which is the same guarantee
  `CachingUpdater` gives. A warning is logged when this happens.
  """
  use NervesHubLink.UpdateManager.Updater

  alias NervesHubLink.Downloader
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.UpdateInfo

  require Logger

  @default_cache_dir "/data/nerves_hub_link/firmware"

  # NervesHub hashes firmware in 1 MiB parts when it records `partials_checksums`
  @default_part_size 1024 * 1024

  @default_max_part_attempts 3

  @default_max_concurrent_parts 1

  # bytes read from disk at a time, both when verifying a part and when handing
  # the verified parts to fwup
  @read_size 64 * 1024

  @impl NervesHubLink.UpdateManager.Updater
  def start(state) do
    plan = build_plan(state.update_info)
    update_dir = update_dir(state.update_info)

    :ok = prepare_directories(update_dir, plan.count)

    {pending, verified_bytes} = scan_parts(update_dir, plan)

    spans =
      pending
      |> Map.keys()
      |> contiguous_runs()
      |> split_spans(max_concurrent_parts())

    state =
      Map.merge(state, %{
        plan: plan,
        update_dir: update_dir,
        status: {:downloading, 0},
        # the base updater watches `state.download` for a single download, which
        # isn't how this one works. Leaving it empty routes every exit to
        # `handle_message/2`, where the running downloads are known.
        download: nil,
        fwup: nil,
        downloads: %{},
        queued_spans: [],
        pending: pending,
        remaining_parts: map_size(pending),
        downloaded_bytes: verified_bytes + Enum.sum(Enum.map(spans, &kept_bytes(pending, &1))),
        attempts: %{}
      })

    if pending == %{} do
      Logger.info(
        "[#{log_prefix()}] All #{plan.count} firmware #{parts(plan.count)} already downloaded and verified"
      )

      NervesHubLink.send_update_status({:downloading, 100})

      {:ok, start_fwup(state)}
    else
      Logger.info(
        "[#{log_prefix()}] Downloading firmware: #{url_without_query(state.update_info)}"
      )

      log_starting_point(plan, pending, spans)

      {:ok, start_spans(state, spans)}
    end
  end

  defp log_starting_point(plan, pending, spans) do
    verified = plan.count - map_size(pending)

    Logger.info(
      "[#{log_prefix()}] Downloading #{map_size(pending)} of #{plan.count} #{parts(plan.count)} over #{length(spans)} #{connections(length(spans))}, #{verified} already verified"
    )
  end

  @impl NervesHubLink.UpdateManager.Updater
  def handle_downloader_message({span_id, message}, state) do
    case Map.fetch(state.downloads, span_id) do
      {:ok, span} ->
        handle_span_message(message, span, state)

      # a download that was replaced or has already finished
      :error ->
        {:ok, state}
    end
  end

  @impl NervesHubLink.UpdateManager.Updater
  def handle_message({:apply_part, index}, %{plan: %{count: count}} = state) when index < count do
    case stream_part_to_fwup(state, index) do
      :ok ->
        _ = send(self(), {:apply_part, index + 1})
        {:ok, state}

      :done ->
        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "[#{log_prefix()}] Couldn't read part #{index + 1} of #{count}: #{inspect(reason)}"
        )

        {:stop, {:shutdown, {:error, {:part_unreadable, index, reason}}}, state}
    end
  end

  def handle_message({:apply_part, _index}, state) do
    Logger.debug("[#{log_prefix()}] Every firmware part has been handed to FWUP")
    {:ok, state}
  end

  def handle_message({:EXIT, pid, reason}, %{downloads: downloads} = state)
      when is_map(downloads) do
    case Enum.find(downloads, fn {_span_id, span} -> span.pid == pid end) do
      # a download that was stopped on purpose, or one that has already handed
      # over everything it was asked for
      nil ->
        {:ok, state}

      {_span_id, span} ->
        Logger.error(
          "[#{log_prefix()}] The download of #{span_description(span)} stopped : #{inspect(reason)}"
        )

        {:stop, {:shutdown, {:download_error, reason}}, state}
    end
  end

  def handle_message({:EXIT, _pid, _reason} = message, state) do
    Logger.info("[#{log_prefix()}] :EXIT received (#{inspect(message)})")
    {:ok, state}
  end

  def handle_message(message, state) do
    Logger.info("[#{log_prefix()}] Unhandled message : #{inspect(message)}")
    {:ok, state}
  end

  @impl NervesHubLink.UpdateManager.Updater
  def cleanup(%{downloads: downloads}) when is_map(downloads) do
    Enum.each(downloads, fn {_span_id, span} -> close_part(span) end)
  end

  def cleanup(_state), do: :ok

  @impl NervesHubLink.UpdateManager.Updater
  def log_prefix(), do: "NervesHubLink:PartsUpdater"

  ##
  # Messages from one of the downloads
  #

  defp handle_span_message(:complete, span, state) do
    case seal_part(span, state) do
      {:ok, span, state} -> span_finished(span, state)
      {:retry, state} -> {:ok, state}
      {:stop, _reason, _state} = stop -> stop
    end
  end

  # A range request that lands outside the file being served is answered with a
  # 404 or a 416 rather than the bytes that were asked for. The parts on disk
  # can't be trusted to line up with what the server has, so they go.
  defp handle_span_message({:error, %Mint.HTTPError{reason: {:http_error, status}}}, _span, state)
       when status in [404, 416] do
    Logger.error(
      "[#{log_prefix()}] HTTP #{status} while requesting a byte range. Removing the downloaded parts so the next attempt starts from the beginning."
    )

    _ = File.rm_rf(state.update_dir)

    {:ok, state}
  end

  defp handle_span_message({:error, reason}, _span, state) do
    Logger.error("[#{log_prefix()}] Nonfatal HTTP download error: #{inspect(reason)}")
    {:ok, state}
  end

  defp handle_span_message({:data, data, percent}, span, state) do
    case write(span, state, data) do
      {:ok, _span, state} -> {:ok, report_progress(state, percent)}
      {:retry, state} -> {:ok, state}
      {:stop, _reason, _state} = stop -> stop
    end
  end

  defp span_finished(span, state) do
    state = %{state | downloads: Map.delete(state.downloads, span.first)}

    case state.queued_spans do
      [next | rest] ->
        {:ok, start_span(%{state | queued_spans: rest}, next)}

      [] ->
        if map_size(state.downloads) == 0, do: downloads_finished(state), else: {:ok, state}
    end
  end

  defp downloads_finished(%{remaining_parts: 0} = state) do
    NervesHubLink.send_update_status({:downloading, 100})

    Logger.info(
      "[#{log_prefix()}] Firmware download complete (#{state.plan.count} #{parts(state.plan.count)})"
    )

    {:ok, start_fwup(state)}
  end

  defp downloads_finished(state) do
    Logger.error(
      "[#{log_prefix()}] The download finished with #{state.remaining_parts} of #{state.plan.count} #{parts(state.plan.count)} still missing"
    )

    {:stop, {:shutdown, {:download_error, :incomplete_download}}, state}
  end

  ##
  # Working out what to download
  #

  # A plan describes how the firmware is split up: the size of each part, the
  # expected checksum of each part (`nil` when there isn't one to check
  # against), how many parts there are, and the total size when NervesHub sent
  # one.
  defp build_plan(%UpdateInfo{} = update_info) do
    part_size = Keyword.get(settings(), :part_size, @default_part_size)

    case decode_checksums(update_info.partials_checksums) do
      {:ok, []} ->
        Logger.warning(
          "[#{log_prefix()}] The update payload has no part checksums, so the download can't be verified part by part. Is the NervesHub server up to date?"
        )

        whole_file_plan(update_info)

      {:ok, checksums} ->
        expected = part_count(update_info.size, part_size)

        if is_nil(expected) or expected == length(checksums) do
          %{
            part_size: part_size,
            checksums: List.to_tuple(checksums),
            count: length(checksums),
            size: update_info.size
          }
        else
          Logger.error(
            "[#{log_prefix()}] A #{update_info.size} byte firmware split into #{part_size} byte parts needs #{expected} checksums, but the update payload has #{length(checksums)}. Check the :part_size configuration."
          )

          whole_file_plan(update_info)
        end

      :error ->
        Logger.error(
          "[#{log_prefix()}] The part checksums in the update payload aren't hex encoded, ignoring them"
        )

        whole_file_plan(update_info)
    end
  end

  defp whole_file_plan(%UpdateInfo{} = update_info) do
    %{
      part_size: update_info.size,
      checksums: {decode_checksum(update_info.checksum)},
      count: 1,
      size: update_info.size
    }
  end

  defp decode_checksums(checksums) when is_list(checksums) do
    Enum.reduce_while(checksums, {:ok, []}, fn checksum, {:ok, acc} ->
      case decode_checksum(checksum) do
        nil -> {:halt, :error}
        decoded -> {:cont, {:ok, [decoded | acc]}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      :error -> :error
    end
  end

  defp decode_checksums(_checksums), do: {:ok, []}

  defp decode_checksum(checksum) when is_binary(checksum) do
    case Base.decode16(checksum, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end

  defp decode_checksum(_checksum), do: nil

  defp part_count(size, part_size) when is_integer(size) and size > 0 and part_size > 0 do
    div(size - 1, part_size) + 1
  end

  defp part_count(_size, _part_size), do: nil

  # Looks at every part on disk rather than stopping at the first gap, because
  # downloads that ran side by side don't necessarily leave one behind. Returns
  # the parts that still need downloading, along with how many of each one's
  # bytes could be kept, and how much of the firmware is already verified.
  defp scan_parts(update_dir, plan) do
    Enum.reduce(0..(plan.count - 1)//1, {%{}, 0}, fn index, {pending, verified_bytes} ->
      case inspect_part(update_dir, plan, index) do
        {:verified, size} -> {pending, verified_bytes + size}
        {:pending, size} -> {Map.put(pending, index, size), verified_bytes}
      end
    end)
  end

  defp inspect_part(update_dir, plan, index) do
    path = part_path(update_dir, index)
    expected_size = expected_part_size(plan, index)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size == expected_size ->
        if verified_part?(plan, index, path, size), do: {:verified, size}, else: {:pending, 0}

      # a part that was still being written when the device restarted. The
      # bytes are kept and the rest of the part is downloaded, and the checksum
      # still gets the final say on whether they were any good.
      {:ok, %File.Stat{size: size}} when is_integer(expected_size) and size < expected_size ->
        {:pending, size}

      {:ok, %File.Stat{size: size}} when is_nil(expected_size) ->
        {:pending, size}

      _ ->
        {:pending, 0}
    end
  end

  defp verified_part?(plan, index, path, size) do
    case elem(plan.checksums, index) do
      nil ->
        true

      checksum ->
        if file_checksum(path, size) == checksum do
          true
        else
          Logger.warning(
            "[#{log_prefix()}] Part #{index + 1} of #{plan.count} was already on disk but failed verification"
          )

          false
        end
    end
  end

  # Parts next to each other are downloaded together so that one connection
  # covers as many of them as it can.
  defp contiguous_runs(indexes) do
    indexes
    |> Enum.sort()
    |> Enum.reduce([], fn
      index, [{first, last} | rest] when index == last + 1 -> [{first, index} | rest]
      index, runs -> [{index, index} | runs]
    end)
    |> Enum.reverse()
  end

  # Splits the longest range in two until there are enough of them to keep every
  # connection busy, or until they are down to a single part each.
  defp split_spans([], _concurrency), do: []

  defp split_spans(spans, concurrency) when length(spans) >= concurrency, do: spans

  defp split_spans(spans, concurrency) do
    longest = Enum.max_by(spans, &span_length/1)

    if span_length(longest) > 1 do
      {first, last} = longest
      middle = first + div(span_length(longest), 2)

      spans
      |> List.delete(longest)
      |> Enum.concat([{first, middle - 1}, {middle, last}])
      |> Enum.sort()
      |> split_spans(concurrency)
    else
      spans
    end
  end

  defp span_length({first, last}), do: last - first + 1

  # Only the part a range starts at can keep what an earlier attempt left in it.
  defp kept_bytes(%{pending: pending}, index), do: Map.get(pending, index, 0)
  defp kept_bytes(pending, {first, _last}), do: Map.get(pending, first, 0)

  ##
  # Downloading
  #

  defp start_spans(state, spans) do
    {start_now, queued} = Enum.split(spans, max_concurrent_parts())

    Enum.reduce(start_now, %{state | queued_spans: queued}, &start_span(&2, &1))
  end

  defp start_span(state, {first, last}) do
    span =
      open_part(%{first: first, last: last, pid: nil}, state, first, kept_bytes(state, first))

    Logger.debug("[#{log_prefix()}] Downloading #{span_description(span)}")

    put_in(state.downloads[first], start_download(span, state))
  end

  defp start_download(span, state) do
    span_id = span.first
    updater = self()

    {:ok, pid} =
      Downloader.start_download(
        URI.to_string(state.update_info.firmware_url),
        fn message -> report_download(updater, {span_id, message}) end,
        resume_from_bytes: part_offset(state.plan, span.index) + span.bytes,
        range_end: span_range_end(state.plan, span.last),
        label: span_description(span)
      )

    %{span | pid: pid}
  end

  # The last range runs to the end of the file, which the server knows better
  # than this does when NervesHub didn't send a size.
  defp span_range_end(%{count: count}, last) when last >= count - 1, do: nil
  defp span_range_end(plan, last), do: part_offset(plan, last + 1) - 1

  # The downloader is blocked waiting on this process while a part is being
  # written, so it can't be asked to stop politely. Killing it is safe because
  # every byte it has handed over is already on disk.
  defp restart_download(span, state) do
    _ = if span.pid, do: Process.exit(span.pid, :kill)

    span =
      span
      |> Map.put(:pid, nil)
      |> open_part(state, span.index, 0)
      |> start_download(state)

    {span, put_in(state.downloads[span.first], span)}
  end

  defp write(span, state, <<>>), do: {:ok, span, state}

  defp write(span, state, data) do
    room = room_in_part(state.plan, span)

    if is_nil(room) or byte_size(data) < room do
      append(span, state, data)
    else
      fill = binary_part(data, 0, room)
      rest = binary_part(data, room, byte_size(data) - room)

      with {:ok, span, state} <- append(span, state, fill),
           {:ok, span, state} <- seal_part(span, state) do
        continue_writing(span, state, rest)
      end
    end
  end

  defp continue_writing(span, state, <<>>), do: {:ok, span, state}

  defp continue_writing(%{index: index, last: last} = span, state, data) when index <= last do
    write(span, state, data)
  end

  defp continue_writing(span, state, data) do
    Logger.error(
      "[#{log_prefix()}] The download of #{span_description(span)} sent #{byte_size(data)} bytes more than the range it was asked for"
    )

    {:stop, {:shutdown, {:download_error, :unexpected_data}}, state}
  end

  defp append(span, state, data) do
    :ok = :file.write(span.fd, data)

    span = %{
      span
      | bytes: span.bytes + byte_size(data),
        hash: :crypto.hash_update(span.hash, data)
    }

    state = %{state | downloaded_bytes: state.downloaded_bytes + byte_size(data)}

    {:ok, span, put_in(state.downloads[span.first], span)}
  end

  defp seal_part(%{fd: nil} = span, state), do: {:ok, span, state}

  defp seal_part(span, state) do
    index = span.index
    _ = File.close(span.fd)

    span = %{span | fd: nil}
    digest = :crypto.hash_final(span.hash)

    case elem(state.plan.checksums, index) do
      checksum when checksum == nil or checksum == digest ->
        log_sealed_part(state.plan, index, checksum)
        advance(span, state)

      _checksum ->
        retry_part(span, state)
    end
  end

  defp log_sealed_part(plan, index, nil) do
    Logger.debug(
      "[#{log_prefix()}] Part #{index + 1} of #{plan.count} downloaded, but there was no checksum to verify it against"
    )
  end

  defp log_sealed_part(plan, index, _checksum) do
    Logger.debug("[#{log_prefix()}] Part #{index + 1} of #{plan.count} verified")
  end

  defp advance(span, state) do
    state = %{state | remaining_parts: state.remaining_parts - 1}

    # the next part in this range is about to be streamed into from its first
    # byte, so anything an earlier attempt left in it is of no use
    span = if span.index < span.last, do: open_part(span, state, span.index + 1, 0), else: span

    {:ok, span, put_in(state.downloads[span.first], span)}
  end

  defp retry_part(span, state) do
    index = span.index
    attempts = Map.update(state.attempts, index, 1, &(&1 + 1))
    attempt = Map.fetch!(attempts, index)
    max_attempts = max_part_attempts()

    _ = File.rm(part_path(state.update_dir, index))

    state =
      %{
        state
        | attempts: attempts,
          downloaded_bytes: state.downloaded_bytes - span.bytes
      }
      |> put_in([:downloads, span.first], span)

    if attempt >= max_attempts do
      Logger.error(
        "[#{log_prefix()}] Part #{index + 1} of #{state.plan.count} failed verification #{attempt} times, giving up. If this keeps happening, check that :part_size matches the size NervesHub hashed the firmware with."
      )

      {:stop, {:shutdown, {:error, {:part_verification_failed, index}}}, state}
    else
      Logger.warning(
        "[#{log_prefix()}] Part #{index + 1} of #{state.plan.count} failed verification, downloading it again (attempt #{attempt + 1} of #{max_attempts})"
      )

      {_span, state} = restart_download(span, state)

      {:retry, state}
    end
  end

  defp report_progress(state, downloader_percent) do
    percent = round(overall_percent(state, downloader_percent))

    if send_update?(state, percent) do
      NervesHubLink.send_update_status({:downloading, percent})

      state
      |> Map.put(:status, {:downloading, percent})
      |> Map.put(:last_progress_message, System.monotonic_time(:millisecond))
    else
      state
    end
  end

  # Each download only knows about its own range, so progress is counted from
  # what is on disk rather than from any one of them.
  defp overall_percent(%{plan: %{size: size}} = state, _downloader_percent)
       when is_integer(size) and size > 0 do
    state.downloaded_bytes / size * 100
  end

  defp overall_percent(_state, downloader_percent), do: downloader_percent

  ##
  # Applying
  #

  defp start_fwup(state) do
    Logger.info("[#{log_prefix()}] Requesting FWUP apply the firmware update")

    {:ok, fwup} =
      Fwup.stream(self(), fwup_args(state.fwup_config, state.fwup_public_keys),
        fwup_env: state.fwup_config.fwup_env
      )

    _ = send(self(), {:apply_part, 0})

    Map.merge(state, %{fwup: fwup, status: {:updating, 0}, last_progress_message: nil})
  end

  defp stream_part_to_fwup(state, index) do
    path = part_path(state.update_dir, index)

    case File.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          send_chunks(state.fwup, fd)
        after
          _ = File.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_chunks(fwup, fd) do
    case :file.read(fd, @read_size) do
      {:ok, data} ->
        case send_chunk(fwup, data) do
          :ok -> send_chunks(fwup, fd)
          :done -> :done
        end

      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_chunk(fwup, data) do
    :ok = Fwup.Stream.send_chunk(fwup, data)
    :ok
  catch
    :exit, reason ->
      # FWUP stopped before it was handed every byte, which is what happens when
      # it has already seen everything it needs. Whether that was a success or a
      # failure arrives separately as an fwup message.
      Logger.debug("[#{log_prefix()}] FWUP stopped accepting data: #{inspect(reason)}")
      :done
  end

  @spec fwup_args(FwupConfig.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%FwupConfig{} = config, fwup_public_keys) do
    args =
      [
        "--apply",
        "--no-unmount",
        "-d",
        config.fwup_devpath,
        "--task",
        config.fwup_task
      ] ++ config.fwup_extra_options

    Enum.reduce(fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end

  ##
  # Parts on disk
  #

  defp open_part(span, state, index, existing_bytes) do
    path = part_path(state.update_dir, index)

    {hash, fd, bytes} =
      case existing_hash(path, existing_bytes) do
        {:ok, hash} ->
          {hash, File.open!(path, [:read, :append, :raw, :binary]), existing_bytes}

        :error ->
          _ = File.rm(path)
          {:crypto.hash_init(:sha256), File.open!(path, [:write, :raw, :binary]), 0}
      end

    Map.merge(span, %{index: index, fd: fd, bytes: bytes, hash: hash})
  end

  defp close_part(%{fd: fd}) when not is_nil(fd) do
    case File.close(fd) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[#{log_prefix()}] Failed to close the part being written: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp close_part(_span), do: :ok

  defp existing_hash(_path, 0), do: :error

  defp existing_hash(path, bytes) do
    case hash_file(path, bytes) do
      {:ok, hash} ->
        {:ok, hash}

      {:error, reason} ->
        Logger.warning(
          "[#{log_prefix()}] Couldn't read the part already on disk (#{inspect(reason)}), starting it again"
        )

        :error
    end
  end

  defp file_checksum(path, bytes) do
    case hash_file(path, bytes) do
      {:ok, hash} -> :crypto.hash_final(hash)
      {:error, _reason} -> nil
    end
  end

  defp hash_file(path, bytes) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          hash_bytes(fd, :crypto.hash_init(:sha256), bytes)
        after
          _ = File.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_bytes(_fd, hash, 0), do: {:ok, hash}

  defp hash_bytes(fd, hash, remaining) do
    case :file.read(fd, min(remaining, @read_size)) do
      {:ok, data} ->
        hash_bytes(fd, :crypto.hash_update(hash, data), remaining - byte_size(data))

      :eof ->
        {:ok, hash}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp room_in_part(plan, span) do
    case expected_part_size(plan, span.index) do
      nil -> nil
      size -> size - span.bytes
    end
  end

  # Every part is `part_size` bytes apart from the last one, which holds
  # whatever is left over. `nil` means the size isn't known, which only happens
  # when NervesHub didn't send one, and the part is finished when the download
  # is.
  defp expected_part_size(%{part_size: nil}, _index), do: nil
  defp expected_part_size(%{size: nil, part_size: part_size}, _index), do: part_size

  defp expected_part_size(%{size: size, part_size: part_size}, index) do
    min(part_size, size - index * part_size)
  end

  defp part_offset(_plan, 0), do: 0
  defp part_offset(%{part_size: part_size}, index), do: index * part_size

  defp part_path(update_dir, index) do
    Path.join(update_dir, "part-" <> String.pad_leading(Integer.to_string(index), 5, "0"))
  end

  defp prepare_directories(update_dir, count) do
    :ok = remove_other_firmware(Path.dirname(update_dir), Path.basename(update_dir))
    :ok = File.mkdir_p(update_dir)
    remove_unexpected_parts(update_dir, count)
  end

  defp remove_other_firmware(cache_dir, keep) do
    with {:ok, entries} <- File.ls(cache_dir),
         [_ | _] = stale <- Enum.reject(entries, &(&1 == keep)) do
      Logger.info(
        "[#{log_prefix()}] Removing #{length(stale)} previous firmware download(s) from the cache directory"
      )

      Enum.each(stale, &File.rm_rf(Path.join(cache_dir, &1)))
    else
      _ -> :ok
    end
  end

  # Anything that isn't a part of this download, such as parts left behind after
  # a change to `:part_size`, would otherwise sit in the cache directory forever.
  defp remove_unexpected_parts(update_dir, count) do
    case File.ls(update_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&expected_part?(&1, count))
        |> Enum.each(&File.rm_rf(Path.join(update_dir, &1)))

      {:error, _reason} ->
        :ok
    end
  end

  defp expected_part?("part-" <> index, count) do
    case Integer.parse(index) do
      {index, ""} -> index < count
      _ -> false
    end
  end

  defp expected_part?(_entry, _count), do: false

  defp update_dir(%UpdateInfo{} = update_info) do
    Path.join(cache_dir(), update_id(update_info))
  end

  # The firmware URL is signed and changes between attempts, so the firmware
  # UUID is what ties a download to the update it belongs to.
  defp update_id(%UpdateInfo{firmware_meta: %{uuid: uuid}}) when is_binary(uuid) and uuid != "" do
    safe_name(uuid)
  end

  defp update_id(%UpdateInfo{firmware_url: firmware_url}) do
    firmware_url
    |> URI.to_string()
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/\?.*/, "")
    |> safe_name()
  end

  # Nothing in the payload should be trusted to name a directory. Dots are
  # replaced along with everything else so that a name of ".." can't walk out of
  # the cache directory and take the contents of its parent with it.
  defp safe_name(name) do
    case String.replace(name, ~r/[^A-Za-z0-9_-]/, "_") do
      "" -> "firmware"
      name -> name
    end
  end

  defp url_without_query(%UpdateInfo{firmware_url: firmware_url}) do
    firmware_url
    |> URI.to_string()
    |> String.replace(~r/\?.*/, "?...")
  end

  defp span_description(%{first: first, last: last}) when first == last do
    "part #{first + 1}"
  end

  defp span_description(%{first: first, last: last}) do
    "parts #{first + 1} to #{last + 1}"
  end

  defp parts(1), do: "part"
  defp parts(_count), do: "parts"

  defp connections(1), do: "connection"
  defp connections(_count), do: "connections"

  defp settings(), do: Application.get_env(:nerves_hub_link, __MODULE__, [])

  defp cache_dir(), do: Keyword.get(settings(), :cache_dir, @default_cache_dir)

  defp max_part_attempts(),
    do: Keyword.get(settings(), :max_part_attempts, @default_max_part_attempts)

  defp max_concurrent_parts() do
    settings()
    |> Keyword.get(:max_concurrent_parts, @default_max_concurrent_parts)
    |> max(1)
  end
end
