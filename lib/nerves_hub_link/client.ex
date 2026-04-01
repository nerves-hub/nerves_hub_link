# SPDX-FileCopyrightText: 2018 Connor Rigby
# SPDX-FileCopyrightText: 2019 Frank Hunleth
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2020 Justin Schneck
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Client do
  @moduledoc """
  The primary integration point for customizing your applications connection with [NervesHub](https://github.com/nerves-hub/nerves_hub_web).

  The following callbacks are supported:

  - `c:archive_available/1` - an archive is available to download from NervesHub
  - `c:archive_ready/2` - an archive has been downloaded and is available for use
  - `c:connected/0` - a connection to NervesHub has been established
  - `c:firmware_auto_revert_detected?/0` - checks if a firmware revert occurred
  - `c:firmware_validated?/0` - checks if the current firmware has been validated
  - `c:handle_error/1` - a firmware update has failed
  - `c:handle_fwup_message/1` - a message has been received by `NervesHubLink.UpdateManager`
  - `c:identify/0` - a request received from NervesHub to identify the device (eg. blink leds)
  - `c:reboot/0` - a request received from NervesHub to reboot the device
  - `c:reconnect_backoff/0` - how NervesHubLink should handle reconnection backoffs
  - `c:update_available/1` - should a firmware update be applied

  A default Client is included (`NervesHubLink.Client.Default`) which `:apply`s firmware
  updates, `:ignore`s archives, logs firmware update messages, and logs a message when
  the `identify/0` callback is used.

  The recommended way to implement your own `Client` is to create your own module and add
  `use NervesHubLink.Client`, which will allow you to use the same defaults included in
  `NervesHubLink.Client.Default`, while also being able to customize any of the current
  callback implementations.

  Otherwise you can add `@behaviour NervesHubLink.Client`, but you will need to implement
  the following required functions:

  - `c:archive_available/1`
  - `c:archive_ready/2`
  - `c:handle_error/1`
  - `c:handle_fwup_message/1`
  - `c:identify/0`
  - `c:update_available/1`

  # Example

  ```elixir
  defmodule MyApp.NervesHubLinkClient do
    use NervesHubLink.Client

    # override only the functions you want to customize

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

  To have NervesHubLink use your client, add the following to your `config.exs`:

  ```elixir
  config :nerves_hub_link, client: MyApp.NervesHubLinkClient
  ```
  """

  alias Nerves.Runtime
  alias Nerves.Runtime.KV
  alias NervesHubLink.Backoff

  require Logger

  @typedoc "Update that comes over a socket."
  @type update_data :: NervesHubLink.Message.UpdateInfo.t()

  @typedoc "Archive that comes over a socket."
  @type archive_data :: NervesHubLink.Message.ArchiveInfo.t()

  @typedoc "Supported responses from `update_available/1`"
  @type update_response ::
          :apply
          | :ignore
          | {:ignore, String.t()}
          | {:reschedule, pos_integer()}
          | {:reschedule, pos_integer(), String.t()}

  @typedoc "Supported responses from `archive_available/1`"
  @type archive_response :: :download | :ignore | {:reschedule, pos_integer()}

  @typedoc "Firmware update progress, completion or error report"
  @type fwup_message ::
          {:ok, non_neg_integer(), String.t()}
          | {:warning, non_neg_integer(), String.t()}
          | {:error, non_neg_integer(), String.t()}
          | {:progress, 0..100}

  @doc """
  Called when the connection to NervesHub has been established.

  The return value of this function is not checked.
  """
  @callback connected() :: any

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
  Optional callback when the socket disconnected, before starting to reconnect.

  The return value is used to reset the next socket's retry timeout. `nil` asks NervesHubLink
  to calculate a set of random backoffs to use.

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
  Optional callback to reboot the device when a firmware update completes

  The default behavior is to call `Nerves.Runtime.reboot/0` after a successful update. This
  is useful for testing and for doing additional work like notifying users in a UI that a reboot
  will happen soon. It is critical that a reboot does happen.
  """
  @callback reboot() :: no_return()

  @doc """
  Optional callback to check if the current firmware has been validated.

  The default behavior is to delegate to `Nerves.Runtime.firmware_valid?/0`.

  If there is custom logic built into your `fwup.conf` and `fwup-ops.conf`
  files, you should implement this callback in your `NervesHubLink.Client`.
  """
  @callback firmware_validated?() :: boolean()

  @doc """
  Optional callback to check if an auto firmware revert just occurred.

  The default behavior is to check if the previous firmware slots:
  - `nerves_fw_validated` value is `0`
  - and `nerves_fw_platform` is not empty
  - and `nerves_fw_architecture` is not empty

  If there is custom logic built into `fwup-ops.conf` around `prevent-revert`, this should be
  reflected here.
  """
  @callback firmware_auto_revert_detected?() :: boolean()

  @optional_callbacks [
    connected: 0,
    firmware_auto_revert_detected?: 0,
    firmware_validated?: 0,
    reboot: 0,
    reconnect_backoff: 0
  ]

  @spec connected() :: any
  def connected() do
    if function_exported?(mod(), :connected, 0) do
      apply_wrap(mod(), :connected, [])
    else
      nil
    end
  end

  @doc """
  This function is called internally by NervesHubLink to notify clients.
  """
  @spec update_available(update_data()) :: update_response()
  def update_available(data) do
    case apply_wrap(mod(), :update_available, [data]) do
      :apply ->
        :apply

      :ignore ->
        :ignore

      {:ignore, reason} ->
        {:ignore, reason}

      {:reschedule, timeout} when timeout > 0 ->
        {:reschedule, timeout}

      {:reschedule, timeout_mins, reason} when timeout_mins > 0 ->
        {:reschedule, timeout_mins, reason}

      wrong ->
        Logger.error(
          "[NervesHubLink.Client] #{inspect(mod())}.update_available/1 result not recognized (#{inspect(wrong)}), applying update."
        )

        :apply
    end
  end

  @spec archive_available(archive_data()) :: archive_response()
  def archive_available(data) do
    apply_wrap(mod(), :archive_available, [data])
  end

  @spec archive_ready(archive_data(), Path.t()) :: :ok
  def archive_ready(data, file_path) do
    _ = apply_wrap(mod(), :archive_ready, [data, file_path])

    :ok
  end

  @doc """
  This function is called internally by NervesHubLink to notify clients of fwup progress.
  """
  @spec handle_fwup_message(fwup_message()) :: :ok
  def handle_fwup_message(data) do
    _ = apply_wrap(mod(), :handle_fwup_message, [data])
    :ok
  end

  @doc """
  This function is called internally by NervesHubLink to identify a device.
  """
  @spec identify() :: :ok
  def identify() do
    apply_wrap(mod(), :identify, [])
  end

  @doc """
  This function is called internally by NervesHubLink to initiate a reboot.

  After a successful firmware update, NervesHubLink calls this to start the
  reboot process. It calls `c:reboot/0` if supplied or
  `Nerves.Runtime.reboot/0`.
  """
  @spec initiate_reboot() :: :ok
  def initiate_reboot() do
    client = mod()

    {mod, fun, args} =
      if function_exported?(client, :reboot, 0),
        do: {client, :reboot, []},
        else: {Nerves.Runtime, :reboot, []}

    _ = spawn(mod, fun, args)
    :ok
  end

  @doc """
  This function is called internally by NervesHubLink to notify clients of fwup errors.
  """
  @spec handle_error(any()) :: :ok
  def handle_error(data) do
    _ = apply_wrap(mod(), :handle_error, [data])
  end

  @doc """
  This function is called internally by NervesHubLink to notify clients of disconnects.
  """
  @spec reconnect_backoff() :: [integer()]
  def reconnect_backoff() do
    backoff =
      if function_exported?(mod(), :reconnect_backoff, 0) do
        apply_wrap(mod(), :reconnect_backoff, [])
      else
        nil
      end

    if is_list(backoff) do
      backoff
    else
      Backoff.delay_list(1000, 60000, 0.50)
    end
  end

  @doc """
  A wrapper function which calls `firmware_validated?/0` on the configured `NervesHubLink.Client`.

  If the function isn't implemented, the default logic of delegating to
  `Nerves.Runtime.firmware_valid?/0` is used.
  """
  @spec firmware_validated?() :: boolean()
  def firmware_validated?() do
    if function_exported?(mod(), :firmware_validated?, 0) do
      case apply_wrap(mod(), :firmware_validated?, []) do
        is_reverted when is_boolean(is_reverted) ->
          is_reverted

        other ->
          Logger.warning(
            "[NervesHubLink.Client] Invalid response from `#{inspect(mod())}.firmware_validated?/0`, returning true : #{inspect(other)}"
          )

          true
      end
    else
      Runtime.firmware_valid?()
    end
  end

  @doc """
  The common logic to determine if an auto revert occurred is to check if the previous
  firmware is not validated. This is because, for example, if a device boots into
  firmware slot A and isn't able to validate the slot within the initialization
  callback time, the device will reboot into the previous firmware slot, B, and now
  firmware slot A will be shown as not validated.

  We also need to account for the logic used by `prevent-revert` in `fwup-ops.conf`,
  which can be different/custom per Nerves system. The common pattern is to unset
  `nerves_fw_platform` and `nerves_fw_architecture`.

  The default implementation checks if the previous firmware slot is not validated,
  and that `nerves_fw_platform` and `nerves_fw_architecture` are not empty.

  Clears platform and architecture uboot env vars
  - https://github.com/nerves-project/nerves_system_rpi4/blob/main/fwup-ops.conf#L51-L52
  - https://github.com/nerves-project/nerves_system_rpi5/blob/main/fwup-ops.conf#L51-L52

  Clears platform, architecture, and validated uboot env vars
  - https://github.com/nerves-project/nerves_system_rpi4/blob/tryboot-compatible/fwup-ops.conf#L50-L55
  """
  @spec firmware_auto_revert_detected?() :: boolean()
  def firmware_auto_revert_detected?() do
    if function_exported?(mod(), :firmware_auto_revert_detected?, 0) do
      case apply_wrap(mod(), :firmware_auto_revert_detected?, []) do
        is_reverted when is_boolean(is_reverted) ->
          is_reverted

        other ->
          Logger.warning(
            "[NervesHubLink.Client] Invalid response from `#{inspect(mod())}.firmware_auto_revert_detected?/0`, returning false : #{inspect(other)}"
          )

          false
      end
    else
      default_firmware_auto_revert_check()
    end
  end

  defp default_firmware_auto_revert_check() do
    active_slot = KV.get("nerves_fw_active")

    previous_slot =
      KV.get_all()
      |> Enum.filter(fn {k, _v} ->
        String.match?(k, ~r/.\./) and not String.starts_with?(k, "#{active_slot}.")
      end)
      |> Enum.map(fn {k, v} -> {String.replace(k, ~r/\A.{1}\./, ""), v} end)
      |> Enum.into(%{})

    Map.get(previous_slot, "nerves_fw_validated", "1") == "0" &&
      Map.get(previous_slot, "nerves_fw_platform", "") != "" &&
      Map.get(previous_slot, "nerves_fw_architecture", "") != ""
  end

  # Catches exceptions and exits
  defp apply_wrap(mod, function, args) do
    apply(mod, function, args)
  catch
    :error, reason ->
      Logger.error(
        "[NervesHubLink.Client] an error occurred when calling `#{inspect(mod)}.#{inspect(function)} with args #{inspect(args)} : #{inspect(reason)}"
      )

      {:error, reason}

    :exit, reason ->
      Logger.error(
        "[NervesHubLink.Client] an exit occurred when calling `#{inspect(mod)}.#{inspect(function)} with args #{inspect(args)} : #{inspect(reason)}"
      )

      {:exit, reason}

    err ->
      Logger.error(
        "[NervesHubLink.Client] an unrecognized error occurred when calling `#{inspect(mod)}.#{inspect(function)} with args #{inspect(args)} : #{inspect(err)}"
      )

      err
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour NervesHubLink.Client

      alias Nerves.Runtime.KV

      require Logger

      @impl NervesHubLink.Client
      def update_available(update_info) do
        if update_info.firmware_meta.uuid == KV.get_active("nerves_fw_uuid") do
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
        Logger.debug("[NervesHubLink.Client] FWUP PROG: #{percent}%")
      end

      def handle_fwup_message({:error, _, message}) do
        Logger.error("[NervesHubLink.Client] FWUP ERROR: #{message}")
      end

      def handle_fwup_message({:warning, _, message}) do
        Logger.warning("[NervesHubLink.Client] FWUP WARN: #{message}")
      end

      def handle_fwup_message({:ok, status, message}) do
        Logger.info("[NervesHubLink.Client] FWUP SUCCESS: #{status} #{message}")
      end

      def handle_fwup_message(fwup_message) do
        Logger.warning("[NervesHubLink.Client] Unknown FWUP message: #{inspect(fwup_message)}")
      end

      @impl NervesHubLink.Client
      def handle_error(error) do
        Logger.warning("[NervesHubLink.Client] error: #{inspect(error)}")
      end

      @impl NervesHubLink.Client
      def reconnect_backoff() do
        socket_config = Application.get_env(:nerves_hub_link, :socket, [])
        socket_config[:reconnect_after_msec]
      end

      @impl NervesHubLink.Client
      def identify() do
        Logger.info("[NervesHubLink.Client] identifying device")
      end

      defoverridable archive_available: 1,
                     archive_ready: 2,
                     handle_error: 1,
                     handle_fwup_message: 1,
                     identify: 0,
                     reconnect_backoff: 0,
                     update_available: 1
    end
  end

  defp mod() do
    Application.get_env(:nerves_hub_link, :client, NervesHubLink.Client.Default)
  end
end
