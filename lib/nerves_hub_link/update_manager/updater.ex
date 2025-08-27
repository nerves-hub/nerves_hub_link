# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.Updater do
  @moduledoc """
  `Updater`s orchestrate the complete workflow of downloading and installing/applying
  firmware updates.
  """

  @type t :: __MODULE__

  @type standard_response ::
          {:noreply, new_state :: term()}
          | {:noreply, new_state :: term(),
             timeout() | :hibernate | {:continue, continue_arg :: term()}}
          | {:stop, reason :: term(), new_state :: term()}

  @callback start(state :: term()) :: {:ok, new_state :: term()}
  @callback handle_downloader_message(message :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:stop, reason :: term(), new_state :: term()}
  @callback handle_fwup_message(message :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:stop, reason :: term(), new_state :: term()}
  @callback log_prefix() :: String.t()

  defmacro __using__(_opts) do
    quote do
      use GenServer

      @behaviour NervesHubLink.UpdateManager.Updater

      alias NervesHubLink.Alarms
      alias NervesHubLink.FwupConfig
      alias NervesHubLink.Message.UpdateInfo

      require Logger

      @spec start_update(
              UpdateInfo.t(),
              FwupConfig.t(),
              fwup_public_keys :: []
            ) ::
              GenServer.on_start()
      def start_update(update_info, fwup_config, fwup_public_keys) do
        start_link(update_info, fwup_config, fwup_public_keys)
      end

      @spec start_link(
              UpdateInfo.t(),
              FwupConfig.t(),
              fwup_public_keys :: [],
              GenServer.options()
            ) :: GenServer.on_start()
      def start_link(update_info, fwup_config, fwup_public_keys, opts \\ []) do
        GenServer.start_link(
          __MODULE__,
          [update_info, fwup_config, fwup_public_keys],
          opts
        )
      end

      @impl GenServer
      def init([update_info, fwup_config, fwup_public_keys]) do
        fwup_config = FwupConfig.validate!(fwup_config)

        pid = self()

        # Listen for downloader or fwup exits
        Process.flag(:trap_exit, true)

        send(pid, :start)

        {:ok,
         %{
           fwup_config: fwup_config,
           fwup_public_keys: fwup_public_keys,
           update_info: update_info,
           reporting_download_fun: &report_download(pid, &1)
         }}
      end

      @impl GenServer
      def handle_info(:start, state) do
        {:ok, state} = start(state)
        {:noreply, state}
      end

      def handle_info({:fwup, message}, state) do
        case handle_fwup_message(message, state) do
          {:ok, state} -> {:noreply, state}
          {:stop, _reason, _state} = result -> result
        end
      end

      def handle_info({:EXIT, download_pid, :normal}, %{download: download_pid} = state) do
        Logger.debug("[#{log_prefix()}] Downloader exited")

        {:noreply, state}
      end

      def handle_info({:EXIT, _, _} = msg, state) do
        Logger.info(
          "[#{log_prefix()}] :EXIT received (#{inspect(msg)}), state: #{inspect(state)}"
        )

        {:noreply, state}
      end

      @impl GenServer
      def handle_call({:downloader, message}, _from, state) do
        {:ok, state} = handle_downloader_message(message, state)
        {:reply, :ok, state}
      end

      @impl NervesHubLink.UpdateManager.Updater
      def handle_fwup_message(fwup_message, state) do
        _ = state.fwup_config.handle_fwup_message.(fwup_message)

        case fwup_message do
          {:ok, 0, _message} ->
            Logger.info("[#{log_prefix()}] Update Finished")
            Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
            NervesHubLink.Client.initiate_reboot()
            {:stop, {:shutdown, :update_complete}, state}

          {:progress, percent} ->
            NervesHubLink.send_update_progress(percent)
            {:ok, Map.put(state, :status, {:updating, percent})}

          {:error, _, message} ->
            Logger.warning("[#{log_prefix()}] Error applying update : #{inspect(message)}")
            NervesHubLink.send_update_status("fwup error #{message}")
            Alarms.clear_alarm(NervesHubLink.UpdateInProgress)
            {:stop, {:shutdown, {:fwup_error, message}}, state}

          _ ->
            {:ok, state}
        end
      end

      @impl NervesHubLink.UpdateManager.Updater
      def log_prefix(), do: "NervesHubLink:Updater"

      defp report_download(updater, message) do
        # 60 seconds is arbitrary, but currently matches the `fwup` library's
        # default timeout. Having fwup take longer than 5 seconds to perform a
        # write operation seems remote except for perhaps an exceptionally well
        # compressed delta update. The consequences of crashing here because fwup
        # doesn't have enough time are severe, though, since they prevent an
        # update.
        GenServer.call(updater, {:downloader, message}, 60_000)
      end

      defoverridable init: 1, handle_fwup_message: 2, log_prefix: 0
    end
  end
end
