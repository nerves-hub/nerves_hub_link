defmodule NervesHubLink.Client do
  @moduledoc """
  A behaviour module for customizing if and when firmware updates get applied.

  By default NervesHubLink applies updates as soon as it knows about them from the
  NervesHubLink server and doesn't give warning before rebooting. This let's
  devices hook into the decision making process and monitor the update's
  progress.

  # Example

  ```elixir
  defmodule MyApp.NervesHubLinkClient do
    @behaviour NervesHubLink.Client

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
  config :nerves_hub, client: MyApp.NervesHubLinkClient
  ```
  """

  require Logger

  @typedoc "Update that comes over a socket."
  @type update_data :: map()

  @typedoc "Supported responses from `update_available/1`"
  @type update_response :: :apply | :ignore | {:reschedule, pos_integer()}

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
  Optional callback to reboot the device when a firmware update completes

  The default behavior is to call `Nerves.Runtime.reboot/0` after a successful update. This
  is useful for testing and for doing additional work like notifying users in a UI that a reboot
  will happen soon. It is critical that a reboot does happen.
  """
  @callback reboot() :: no_return()

  @optional_callbacks [reboot: 0]

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

      {:reschedule, timeout} when timeout > 0 ->
        {:reschedule, timeout}

      wrong ->
        Logger.error(
          "[NervesHubLink] Client: #{inspect(mod())}.update_available/1 bad return value: #{
            inspect(wrong)
          } Applying update."
        )

        :apply
    end
  end

  @doc """
  This function is called internally by NervesHubLink to notify clients of fwup progress.
  """
  @spec handle_fwup_message(fwup_message()) :: :ok
  def handle_fwup_message(data) do
    _ = apply_wrap(mod(), :handle_fwup_message, [data])

    # TODO: nasty side effects here. Consider moving somewhere else
    case data do
      {:progress, percent} ->
        NervesHubLink.send_update_progress(percent)

      {:error, _, message} ->
        NervesHubLink.send_update_status("fwup error #{message}")

      {:ok, 0, _message} ->
        initiate_reboot()

      _ ->
        :ok
    end
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
        else: {Nerves.Runtime, :reboot, 0}

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

  # Catches exceptions and exits
  defp apply_wrap(mod, function, args) do
    apply(mod, function, args)
  catch
    :error, reason -> {:error, reason}
    :exit, reason -> {:exit, reason}
    err -> err
  end

  defp mod() do
    Application.get_env(:nerves_hub_link, :client, NervesHubLink.Client.Default)
  end
end
