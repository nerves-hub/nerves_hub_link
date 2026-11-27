# SPDX-FileCopyrightText: 2024 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ArchiveManager do
  @moduledoc """
  GenServer for handling downloading archives from NervesHub

  Your NervesHubLink client will tell the manager when to download
  an archive and the Manager will tell your client when it's done
  downloading so you can act on it.

  You are expected to remove the file when you're done with it and track
  that it has been applied to prevent downloading again.
  """

  use GenServer

  alias NervesHubLink.Client
  alias NervesHubLink.Downloader
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.ArchiveInfo

  require Logger

  @type status :: :idle | :downloading | :done | :update_rescheduled

  @typedoc false
  @type t :: %__MODULE__{
          archive_info: nil | ArchiveInfo.t(),
          data_path: Path.t(),
          download: nil | GenServer.server(),
          file_path: Path.t(),
          pending_archive: nil | {ArchiveInfo.t(), [binary()]},
          status: status(),
          temp_file_path: Path.t(),
          update_reschedule_timer: nil | :timer.tref()
        }

  defstruct archive_info: nil,
            data_path: nil,
            download: nil,
            file_path: nil,
            pending_archive: nil,
            status: :idle,
            temp_file_path: nil,
            update_reschedule_timer: nil

  @doc """
  Must be called when an archive payload is dispatched from
  NervesHub. the map must contain a `"url"` key.
  """
  @spec apply_archive(GenServer.server(), ArchiveInfo.t(), [binary()]) :: status()
  def apply_archive(manager \\ __MODULE__, %ArchiveInfo{} = archive_info, verification_keys) do
    GenServer.call(manager, {:apply_archive, archive_info, verification_keys})
  end

  @doc """
  Returns the current status of the archive manager
  """
  @spec status(GenServer.server()) :: status()
  def status(manager \\ __MODULE__) do
    GenServer.call(manager, :status)
  end

  @doc """
  Returns the UUID of the currently downloading archive, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(manager \\ __MODULE__) do
    GenServer.call(manager, :currently_downloading_uuid)
  end

  @doc false
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(args) do
    %{
      start: {__MODULE__, :start_link, [args, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link(map(), GenServer.options()) :: GenServer.on_start()
  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl GenServer
  def init(args) do
    # The downloader is linked to this process. Hear about a download that
    # fails rather than stopping with it.
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      data_path: args.data_path
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(
        {:apply_archive, %ArchiveInfo{} = info, verification_keys},
        _from,
        %__MODULE__{} = state
      ) do
    state = maybe_update_archive(info, verification_keys, state)
    {:reply, state.status, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %__MODULE__{archive_info: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %__MODULE__{} = state) do
    {:reply, state.archive_info.uuid, state}
  end

  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_info({:update_reschedule, response, verification_keys}, state) do
    {:noreply,
     maybe_update_archive(response, verification_keys, %{
       state
       | update_reschedule_timer: nil
     })}
  end

  # messages from Downloader
  def handle_info({:download, :complete, verification_keys}, state) do
    Logger.info("[NervesHubLink] Archive Download complete")

    # Clear a potential old file since we finished downloading
    _ = File.rm_rf(state.file_path)
    _ = File.rename(state.temp_file_path, state.file_path)

    # validate the file

    if valid_archive?(state.file_path, verification_keys) do
      _ = Client.archive_ready(state.archive_info, state.file_path)
    else
      Logger.error(
        "[NervesHubLink] Archive could not be validated, your public signing keys maybe be incorrectly configured"
      )
    end

    {:noreply, state |> reset_download() |> apply_held_archive()}
  end

  def handle_info({:download, {:error, reason}, _verification_keys}, state) do
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Data from the downloader
  def handle_info({:download, {:data, data, _percentage}, _verification_keys}, state) do
    :ok =
      File.open!(state.temp_file_path, [:append], fn fd ->
        IO.binwrite(fd, data)
      end)

    {:noreply, state}
  end

  def handle_info({:EXIT, download, reason}, %__MODULE__{download: download} = state)
      when reason != :normal do
    Logger.error("[NervesHubLink] Archive download failed: #{describe_exit(reason)}")

    _ = File.rm_rf(state.temp_file_path)

    {:noreply, state |> reset_download() |> apply_held_archive()}
  end

  # The download that just finished: its `:complete` already reset the state.
  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  # Nothing else is linked to this process today. Say so rather than swallow it,
  # since exits are trapped and whatever it was would otherwise fail silently.
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning(
      "[NervesHubLink] Ignoring the exit of #{inspect(pid)}, which isn't the archive being downloaded: #{describe_exit(reason)}"
    )

    {:noreply, state}
  end

  # NervesHub can send the same archive message twice, for example when the
  # deployment changes shortly after the device joins. Starting a second
  # download would write into the same file as the first. A repeat is also the
  # latest archive NervesHub has asked for, so drop any held behind it.
  defp maybe_update_archive(
         %ArchiveInfo{uuid: uuid},
         _verification_keys,
         %__MODULE__{status: :downloading, archive_info: %ArchiveInfo{uuid: uuid}} = state
       ) do
    Logger.info("[NervesHubLink] Archive #{uuid} is already downloading, ignoring repeat offer")

    %{state | pending_archive: nil}
  end

  # As with firmware updates, don't interrupt a download in progress. Unlike
  # firmware, nothing asks NervesHub for the archive again: it pushes one when
  # the deployment changes and doesn't repeat it while the device stays
  # connected. So hold the newer archive until the download finishes.
  defp maybe_update_archive(
         %ArchiveInfo{uuid: uuid} = info,
         verification_keys,
         %__MODULE__{status: :downloading, archive_info: %ArchiveInfo{uuid: current}} = state
       ) do
    Logger.info(
      "[NervesHubLink] Archive #{current} is downloading, holding archive #{uuid} until it finishes"
    )

    %{state | pending_archive: {info, verification_keys}}
  end

  defp maybe_update_archive(info, verification_keys, state) do
    if FwupConfig.signing_keys_available?(verification_keys) do
      download_archive(info, verification_keys, state)
    else
      # `fwup -V` exits 0 when it is given no public key, so an unsigned archive
      # would validate. Refuse the archive rather than hand it to the client.
      Logger.error(
        "[NervesHubLink] Refusing archive : no public keys are available to verify the archive signature"
      )

      state
    end
  end

  defp download_archive(info, verification_keys, state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    uri = URI.parse(info.url)
    file_name = Path.basename(uri.path)
    file_path = Path.join(state.data_path, "archives/#{file_name}")
    temp_file_path = Path.join(state.data_path, "archives/#{file_name}.download")
    directory = Path.dirname(file_path)

    pid = self()

    case Client.archive_available(info) do
      :download ->
        handler_fun = fn message ->
          send(pid, {:download, message, verification_keys})

          :ok
        end

        # An archive isn't firmware, and NervesHub takes a download that
        # reports it has started for a firmware update.
        {:ok, download} =
          Downloader.start_download(info.url, handler_fun, report_started: false)

        _ = File.mkdir_p(directory)
        _ = File.rm_rf(temp_file_path)
        _ = File.touch(temp_file_path)

        %{
          state
          | archive_info: info,
            file_path: file_path,
            temp_file_path: temp_file_path,
            download: download,
            status: :downloading
        }

      :ignore ->
        state

      {:reschedule, ms} ->
        timer = Process.send_after(self(), {:update_reschedule, info, verification_keys}, ms)
        Logger.info("[NervesHubLink] rescheduling archive in #{ms} milliseconds")
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  # A download's exit reason can carry a stacktrace whose arguments hold the
  # signed archive URL and the SSL options, which `Downloader.format_status/1`
  # keeps out of the download's own crash report. Name the reasons it stops with
  # on purpose, and reduce anything else to its exception or tag; the download's
  # report has the detail, with the secrets taken out.
  defp describe_exit(reason) when is_atom(reason), do: inspect(reason)
  defp describe_exit({:http_error, status}), do: "HTTP #{status}"

  defp describe_exit(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: inspect(elem(reason, 0))

  defp describe_exit(_reason), do: "an unrecognised reason"

  defp reset_download(%__MODULE__{} = state) do
    %{
      state
      | archive_info: nil,
        file_path: nil,
        temp_file_path: nil,
        download: nil,
        status: :idle
    }
  end

  defp apply_held_archive(%__MODULE__{pending_archive: nil} = state), do: state

  defp apply_held_archive(%__MODULE__{pending_archive: {info, verification_keys}} = state) do
    Logger.info("[NervesHubLink] Offering archive #{info.uuid}, held while one was downloading")

    maybe_update_archive(info, verification_keys, %{state | pending_archive: nil})
  end

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    %{state | update_reschedule_timer: nil}
  end

  defp valid_archive?(file_path, public_keys) do
    if FwupConfig.signing_keys_available?(public_keys) do
      fwup_verify(file_path, public_keys)
    else
      false
    end
  end

  defp fwup_verify(file_path, public_keys) do
    args = ["-V", "-i", file_path]

    args =
      Enum.reduce(public_keys, args, fn public_key, args ->
        args ++ ["--public-key", public_key]
      end)

    {_output, exit_code} = System.cmd("fwup", args)

    exit_code == 0
  end
end
