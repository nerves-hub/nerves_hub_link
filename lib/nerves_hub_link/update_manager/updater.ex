# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.Updater do
  @moduledoc """
  A behaviour to help orchestrate the complete workflow of downloading and installing/applying
  firmware updates.

  This module provides a set of callbacks that must be implemented by any
  updater module. The callbacks are used to start the update process, handle
  messages from the `NervesHubLink.Downloader`, decide when to start the installation via
  the `Fwup` library, and perform any necessary cleanup.

  Creating a new updater module involves implementing the following callbacks:

  - `c:start_update/3`: Called by `NervesHubLink.UpdateManager` to start the update process.
  - `c:start/1`: Callback to setup, prepare, and trigger the download.
  - `c:handle_downloader_message/2`: Process messages from the `NervesHubLink.Downloader`.
  - `c:handle_fwup_message/2`: Process messages received from the `Fwup` library
  - `c:handle_message/2`: Process any other message sent to the updater process.
  - `c:cleanup/1`: Perform any necessary cleanup.

  To simplify the implementation of these callbacks, you can use the provided
  `NervesHubLink.UpdateManager.Updater` module as a base. This module provides
  default implementations for the callbacks, which you can override as needed.

  ### Example Usage

  Here's an example of how to create a new updater module using the provided
  `NervesHubLink.UpdateManager.Updater` module as a base:

  ```elixir
  defmodule MyApp.Updater do
    use NervesHubLink.UpdateManager.Updater

    def start_update(update_info, fwup_config, fwup_public_keys) do
      # Implement the start_update callback
    end

    def start(state) do
      # eg. Setup a temporary directory for storing downloaded files
    end

    def handle_downloader_message(message, state) do
      # eg. Forward packets to the Fwup module
    end

    # Use the default implementation provided by the base module
    #
    # def handle_fwup_message(message, state) do
    # end

    def cleanup(state) do
      # eg. Remove any temporary files or resources created during the update process
    end

    def log_prefix do
      "[MyApp.Updater]"
    end
  end
  ```

  """

  @type t :: __MODULE__

  @type standard_response ::
          {:noreply, new_state :: term()}
          | {:noreply, new_state :: term(),
             timeout() | :hibernate | {:continue, continue_arg :: term()}}
          | {:stop, reason :: term(), new_state :: term()}

  @doc """
  Start an updater GenServer
  """
  @callback start_update(
              NervesHubLink.Message.UpdateInfo.t(),
              NervesHubLink.FwupConfig.t(),
              fwup_public_keys :: []
            ) ::
              GenServer.on_start()

  @doc """
  Setup and prepare for the firmware update.
  """
  @callback start(state :: term()) :: {:ok, new_state :: term()}

  @doc """
  Process messages from the `Downloader`
  """
  @callback handle_downloader_message(message :: term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}
              | {:stop, reason :: term(), new_state :: term()}

  @doc """
  Process messages received from the `Fwup` library
  """
  @callback handle_fwup_message(message :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:stop, reason :: term(), new_state :: term()}

  @doc """
  Process any other message sent to the updater process.

  This is how an updater picks up messages it sends itself, which is useful for
  work that shouldn't happen inside a `c:handle_downloader_message/2` callback -
  the `NervesHubLink.Downloader` blocks while that callback runs, and gives up
  on the updater if it takes too long.

  Exits that aren't from the download in `state.download` arrive here as
  `{:EXIT, pid, reason}`, which is how an updater running more than one
  download at a time finds out that one of them stopped.

  Optional. Updaters built on this module get an implementation that logs and
  carries on.
  """
  @callback handle_message(message :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:stop, reason :: term(), new_state :: term()}

  @optional_callbacks handle_message: 2

  @doc """
  Run any cleanup that might need to take place
  """
  @callback cleanup(state :: term()) :: :ok

  @doc """
  A little hook to allow for customization of the logging prefix
  """
  @callback log_prefix() :: String.t()

  @doc false
  @spec __downloader_reply__(
          {:ok, state}
          | {:error, reason :: term(), state}
          | {:stop, reason :: term(), state}
        ) ::
          {:reply, :ok, state}
          | {:reply, {:error, reason :: term()}, state}
          | {:stop, reason :: term(), {:error, reason :: term()}, state}
        when state: term()
  def __downloader_reply__({:ok, state}), do: {:reply, :ok, state}
  def __downloader_reply__({:error, reason, state}), do: {:reply, {:error, reason}, state}
  def __downloader_reply__({:stop, reason, state}), do: {:stop, reason, {:error, reason}, state}

  @doc false
  @spec __noreply__({:ok, state} | {:stop, reason :: term(), state}) ::
          {:noreply, state} | {:stop, reason :: term(), state}
        when state: term()
  def __noreply__({:ok, state}), do: {:noreply, state}
  def __noreply__({:stop, _reason, _state} = stop), do: stop

  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      use GenServer

      @behaviour NervesHubLink.UpdateManager.Updater

      alias NervesHubLink.Alarms
      alias NervesHubLink.Client
      alias NervesHubLink.FwupConfig
      alias NervesHubLink.Message.UpdateInfo

      require Logger

      @impl NervesHubLink.UpdateManager.Updater
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
           reporting_download_fun: &report_download(pid, &1),
           last_progress_message: nil
         }}
      end

      @impl GenServer
      def handle_info(:start, state) do
        {:ok, state} = start(state)
        {:noreply, state}
      end

      def handle_info({:fwup, message}, state) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        NervesHubLink.UpdateManager.Updater.__noreply__(handle_fwup_message(message, state))
      end

      def handle_info({:EXIT, download_pid, :normal}, %{download: download_pid} = state) do
        Logger.debug("[#{log_prefix()}] Downloader exited")
        {:noreply, state}
      end

      def handle_info({:EXIT, download_pid, reason}, %{download: download_pid} = state) do
        Logger.debug("[#{log_prefix()}] Downloader exited with reason #{inspect(reason)}")
        cleanup(state)
        {:stop, {:shutdown, {:download_error, reason}}, state}
      end

      def handle_info(message, state) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        NervesHubLink.UpdateManager.Updater.__noreply__(handle_message(message, state))
      end

      @impl GenServer
      def handle_call({:downloader, message}, _from, state) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        NervesHubLink.UpdateManager.Updater.__downloader_reply__(
          handle_downloader_message(message, state)
        )
      end

      @impl GenServer
      def terminate(reason, state) do
        cleanup(state)
        :ok
      end

      @impl NervesHubLink.UpdateManager.Updater
      def cleanup(state) do
        :ok
      end

      @impl NervesHubLink.UpdateManager.Updater
      def handle_fwup_message(fwup_message, state) do
        Client.handle_fwup_message(fwup_message)

        case fwup_message do
          {:ok, 0, _message} ->
            {:stop, {:shutdown, :update_complete}, state}

          {:progress, percent} ->
            if send_update?(state, percent) do
              NervesHubLink.send_update_status({:updating, round(percent)})

              state
              |> Map.put(:status, {:updating, round(percent)})
              |> Map.put(:last_progress_message, System.monotonic_time(:millisecond))
              |> then(&{:ok, &1})
            else
              {:ok, state}
            end

          {:error, _, message} ->
            {:stop, {:shutdown, {:fwup_error, message}}, state}

          _ ->
            {:ok, state}
        end
      end

      @impl NervesHubLink.UpdateManager.Updater
      def handle_message({:EXIT, _, _} = message, state) do
        Logger.info(
          "[#{log_prefix()}] :EXIT received (#{inspect(message)}), state: #{inspect(state)}"
        )

        {:ok, state}
      end

      def handle_message(message, state) do
        Logger.info("[#{log_prefix()}] Unhandled message : #{inspect(message)}")
        {:ok, state}
      end

      @impl NervesHubLink.UpdateManager.Updater
      def log_prefix(), do: "NervesHubLink:Updater"

      def send_update?(%{last_progress_message: nil}, _percent), do: true

      def send_update?(%{last_progress_message: lpm, status: {_, previous_progress}}, percent) do
        time_diff = System.monotonic_time(:millisecond) - lpm

        previous_progress < round(percent) and time_diff >= 500
      end

      defp report_download(updater, message) do
        # 60 seconds is arbitrary, but currently matches the `fwup` library's
        # default timeout. Having fwup take longer than 5 seconds to perform a
        # write operation seems remote except for perhaps an exceptionally well
        # compressed delta update. The consequences of crashing here because fwup
        # doesn't have enough time are severe, though, since they prevent an
        # update.
        GenServer.call(updater, {:downloader, message}, 60_000)
      end

      defoverridable init: 1,
                     handle_fwup_message: 2,
                     handle_message: 2,
                     cleanup: 1,
                     log_prefix: 0
    end
  end
end
