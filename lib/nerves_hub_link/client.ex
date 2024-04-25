defmodule NervesHubLink.Client do
  @moduledoc """
  A behaviour module for customizing:
  - if and when firmware updates get applied
  - if and when archives get applied
  - reconnection backoff logic
  - and customizing how a device is identified and rebooted

  By default NervesHubLink applies updates as soon as it knows about them from the
  NervesHubLink server and doesn't give warning before rebooting. This let's
  devices hook into the decision making process and monitor the update's
  progress.

  You can either implement all the callbacks for the `NervesHubLink.Client` behaviour,
  or you can `use NervesHubLink.Client` and override the default implementation.

  # Example

  ```elixir
  defmodule MyApp.NervesHubLinkClient do
    use NervesHubLink.Client

    # May return:
    #  * `:apply` - apply the action immediately
    #  * `:ignore` - don't apply the action, don't ask again.
    #  * `{:reschedule, timeout_in_milliseconds}` - call this function again later.

    @impl NervesHubLink.Client
    def update_available(data) do
      if SomeInternalAPI.is_now_a_good_time_to_update?(data) do
        :apply
      else
        {:reschedule, 60_000}
      end
    end
  end
  ```

  To have NervesHubLink invoke it, add the following to your `config.exs`:

  ```elixir
  config :nerves_hub_link, client: MyApp.NervesHubLinkClient
  ```
  """

  require Logger

  @typedoc "Update that comes over a socket."
  @type update_data :: NervesHubLink.Message.UpdateInfo.t()

  @typedoc "Archive that comes over a socket."
  @type archive_data :: NervesHubLink.Message.ArchiveInfo.t()

  @typedoc "Supported responses from `update_available/1`"
  @type update_response :: :apply | :ignore | {:reschedule, pos_integer()}

  @typedoc "Supported responses from `archive_available/1`"
  @type archive_response :: :download | :ignore | {:reschedule, pos_integer()}

  @typedoc "Firmware update progress, completion or error report"
  @type fwup_message ::
          {:ok, non_neg_integer(), String.t()}
          | {:warning, non_neg_integer(), String.t()}
          | {:error, non_neg_integer(), String.t()}
          | {:progress, 0..100}

  @doc """
  Called to find out what to do when a firmware update is available.

  May return one of:

  * `apply` - Download and apply the update right now.
  * `ignore` - Don't download and apply this update.
  * `{:reschedule, timeout}` - Defer making a decision. Call this function again in `timeout` milliseconds.
  """
  @callback update_available(update_data()) :: update_response()

  @doc """
  Called when an archive is available for download

  May return one of:

  * `download` - Download the archive right now
  * `ignore` - Don't download this archive.
  * `{:reschedule, timeout}` - Defer making a decision. Call this function again in `timeout` milliseconds.
  """
  @callback archive_available(archive_data()) :: archive_response()

  @doc """
  Called when an archive has been downloaded and is available for the application to do something
  """
  @callback archive_ready(archive_data(), Path.t()) :: :ok

  @doc """
  Called on firmware update reports.

  The return value of this function is not checked.
  """
  @callback handle_fwup_message(fwup_message()) :: :ok

  @doc """
  Called when downloading a firmware update fails.

  The return value of this function is not checked.
  """
  @callback handle_error(any()) :: :ok

  @doc """
  Callback when the socket disconnected, before starting to reconnect.

  You may wish to use this to dynamically change the reconnect backoffs. For instance,
  during a NervesHub deploy you may wish to change the reconnect based on your
  own logic to not create a thundering herd of reconnections. If you have a particularly
  flaky connection you can increase how fast the reconnect happens to avoid overloading
  your server.
  """
  @callback reconnect_backoff() :: [integer()] | nil

  @doc """
  Callback to identify the device from NervesHub.
  """
  @callback identify() :: :ok

  @doc """
  Callback to reboot the device when a firmware update completes
  """
  @callback reboot() :: no_return()

  defmacro __using__(_opts) do
    quote do
      @behaviour NervesHubLink.Client
      require Logger

      @impl NervesHubLink.Client
      def update_available(update_info) do
        if update_info.firmware_meta.uuid == Nerves.Runtime.KV.get_active("nerves_fw_uuid") do
          Logger.info("""
          [NervesHubLink.Client] Ignoring request to update to the same firmware

          #{inspect(update_info)}
          """)

          :ignore
        else
          :apply
        end
      end

      @impl NervesHubLink.Client
      def archive_available(archive_info) do
        Logger.info(
          "[NervesHubLink.Client] Archive is available for downloading #{inspect(archive_info)}"
        )

        :ignore
      end

      @impl NervesHubLink.Client
      def archive_ready(archive_info, file_path) do
        Logger.info(
          "[NervesHubLink.Client] Archive is ready for processing #{inspect(archive_info)} at #{inspect(file_path)}"
        )

        :ok
      end

      @impl NervesHubLink.Client
      def handle_fwup_message({:progress, percent}) do
        Logger.debug("FWUP PROG: #{percent}%")
        NervesHubLink.send_update_progress(percent)
        :ok
      end

      def handle_fwup_message({:error, _, message}) do
        Logger.error("FWUP ERROR: #{message}")
        NervesHubLink.send_update_status("fwup error #{message}")
        :ok
      end

      def handle_fwup_message({:warning, _, message}) do
        Logger.warning("FWUP WARN: #{message}")
        :ok
      end

      def handle_fwup_message({:ok, status, message}) do
        Logger.info("FWUP SUCCESS: #{status} #{message}")
        reboot()
        :ok
      end

      def handle_fwup_message(fwup_message) do
        Logger.warning("Unknown FWUP message: #{inspect(fwup_message)}")
        :ok
      end

      @impl NervesHubLink.Client
      def handle_error(error) do
        Logger.warning("[NervesHubLink] error: #{inspect(error)}")
      end

      @doc """
      The default implementation checks if the `:reconnect_after_msec` config has been
      configured, and is a list of values, otherwise `NervesHubLink.Backoff.delay_list/3`
      is used with a minimum value of 1 second, maximum value of 60 seconds, and a 50% jitter.
      """
      @impl NervesHubLink.Client
      def reconnect_backoff() do
        socket_config = Application.get_env(:nerves_hub_link, :socket, [])

        backoff = socket_config[:reconnect_after_msec]

        if is_list(backoff) do
          backoff
        else
          NervesHubLink.Backoff.delay_list(1000, 60000, 0.50)
        end
      end

      @doc """
      The default implementation calls `Nerves.Runtime.reboot/0` after a successful update. This
      is useful for testing and for doing additional work like notifying users in a UI that a reboot
      will happen soon. It is critical that a reboot does happen.
      """
      @impl NervesHubLink.Client
      def reboot() do
        _ = spawn(Nerves.Runtime, :reboot, [])
      end

      @impl NervesHubLink.Client
      def identify() do
        Logger.info("[NervesHubLink] identifying")
      end

      defoverridable NervesHubLink.Client
    end
  end
end
