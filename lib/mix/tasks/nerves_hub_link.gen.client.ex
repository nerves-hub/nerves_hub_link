# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.NervesHubLink.Gen.Client.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc() do
    "Generates a NervesHubLink.Client for your project and configures it."
  end

  @spec example() :: String.t()
  def example() do
    "mix nerves_hub_link.gen.client MyApp.NervesHubClient"
  end

  @spec long_doc() :: String.t()
  def long_doc() do
    """
    #{short_doc()}

    A `NervesHubLink.Client` is how your application decides when a firmware
    update is applied, and how it follows update progress, errors and reboots.

    The generated module does `use NervesHubLink.Client` and overrides each
    callback with a call to the default implementation, so it behaves exactly
    like `NervesHubLink.Client.Default` until you edit it.

    `config :nerves_hub_link, client: <module>` is written to
    `config/target.exs` when it exists, and to `config/config.exs` otherwise.
    A `client` that is already configured is kept, and an existing module is
    never overwritten.

    If `mix.exs` restricts the `nerves_hub_link` dependency with `targets:`,
    the module is wrapped in `if Code.ensure_loaded?(NervesHubLink.Client)` so
    that host builds, which then don't have NervesHubLink, still compile.

    ## Example

    ```bash
    #{example()}
    ```

    ## Arguments

    * `client_module` - The module to generate. Defaults to
      `<YourApp>.NervesHubClient`.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NervesHubLink.Gen.Client do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Project.Config
    alias Igniter.Project.Deps

    @default_suffix "NervesHubClient"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :nerves_hub_link,
        example: __MODULE__.Docs.example(),
        positional: [client_module: [optional: true]]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      case client_module(igniter) do
        {:ok, module} ->
          igniter
          |> create_client(module)
          |> configure_client(module)

        {:error, name} ->
          Igniter.add_issue(
            igniter,
            "#{inspect(name)} is not a valid module name. Expected something like MyApp.NervesHubClient"
          )
      end
    end

    defp client_module(igniter) do
      case igniter.args.positional[:client_module] do
        nil ->
          {:ok, Igniter.Project.Module.module_name(igniter, @default_suffix)}

        name ->
          if name =~ ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/ do
            {:ok, Igniter.Project.Module.parse(name)}
          else
            {:error, name}
          end
      end
    end

    defp create_client(igniter, module) do
      path = Igniter.Project.Module.proper_location(igniter, module)
      {module_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

      cond do
        module_exists? ->
          Igniter.add_notice(igniter, """
          nerves_hub_link: `#{inspect(module)}` already exists and was left as it is.
          """)

        Igniter.exists?(igniter, path) ->
          Igniter.add_notice(igniter, """
          nerves_hub_link: `#{path}` already exists and was left as it is, so
          `#{inspect(module)}` was not generated.
          """)

        true ->
          guarded? = target_only_dep?(igniter)

          igniter
          |> Igniter.create_new_file(path, client_source(module, guarded?))
          |> created_notice(module, path, guarded?)
      end
    end

    # A dependency that's only there for some targets isn't there for host
    # builds, where `use NervesHubLink.Client` then fails to compile.
    defp target_only_dep?(igniter) do
      case Deps.get_dep(igniter, :nerves_hub_link) do
        {:ok, dep} when is_binary(dep) -> dep =~ ~r/\btargets:/
        _ -> false
      end
    end

    defp created_notice(igniter, module, path, guarded?) do
      guard_note =
        if guarded? do
          """

          `mix.exs` only includes nerves_hub_link for some targets, so the module
          is wrapped in `if Code.ensure_loaded?(NervesHubLink.Client)` and isn't
          defined in builds without NervesHubLink, such as the host's.
          """
        else
          ""
        end

      Igniter.add_notice(
        igniter,
        """
        nerves_hub_link: generated `#{inspect(module)}` in `#{path}`. It behaves
        like the default client until you edit it. `update_available/1` is where
        to decide when a firmware update is applied.
        #{guard_note}\
        """
        |> String.trim_trailing()
      )
    end

    defp configure_client(igniter, module) do
      nerves? = Igniter.exists?(igniter, "config/target.exs")
      config_file = if nerves?, do: "target.exs", else: "config.exs"

      case configured_in(igniter) do
        nil ->
          igniter
          |> Config.configure_new(config_file, :nerves_hub_link, [:client], module)
          |> non_nerves_notice(nerves?)

        file ->
          existing_client_notice(igniter, file, module)
      end
    end

    defp configured_in(igniter) do
      Enum.find(["target.exs", "config.exs"], fn file ->
        Igniter.exists?(igniter, Path.join("config", file)) and
          Config.configures_key?(igniter, file, :nerves_hub_link, [:client])
      end)
    end

    # Nothing to say when the configured client is the one asked for, which is
    # the case when the task is run again.
    defp existing_client_notice(igniter, file, module) do
      path = Path.join("config", file)

      content =
        igniter
        |> Igniter.include_existing_file(path)
        |> Map.fetch!(:rewrite)
        |> Rewrite.source!(path)
        |> Rewrite.Source.get(:content)

      if content =~ ~r/\bclient(:|,)\s*#{Regex.escape(inspect(module))}(?![\w.])/ do
        igniter
      else
        Igniter.add_notice(igniter, """
        nerves_hub_link: `config/#{file}` already sets a `client` for
        `:nerves_hub_link`, which was kept. To use `#{inspect(module)}`, change it
        to:

            config :nerves_hub_link, client: #{inspect(module)}
        """)
      end
    end

    defp non_nerves_notice(igniter, true), do: igniter

    defp non_nerves_notice(igniter, false) do
      Igniter.add_notice(igniter, """
      nerves_hub_link: no `config/target.exs` was found, so the `client` setting
      went into `config/config.exs`. `mix nerves_hub_link.gen.client` is intended
      for Nerves projects, where the setting only applies to the device.
      """)
    end

    defp client_source(module, false), do: module_source(module)

    defp client_source(module, true) do
      """
      # nerves_hub_link is only a dependency for some targets, so this module is
      # only defined in builds that include it.
      if Code.ensure_loaded?(NervesHubLink.Client) do
      #{module_source(module)}end
      """
    end

    # Every callback that `use NervesHubLink.Client` defines is overridden with
    # a call to `super`, which is that default. See `NervesHubLink.Client` for
    # the callbacks and what they may return.
    defp module_source(module) do
      """
      defmodule #{inspect(module)} do
        @moduledoc \"\"\"
        Customizes how this device works with NervesHub.

        NervesHubLink calls this module because of
        `config :nerves_hub_link, client: #{inspect(module)}`.

        Every callback below calls `super`, which is the implementation from
        `use NervesHubLink.Client` that `NervesHubLink.Client.Default` also uses.
        Replace the ones you want to customize and delete the rest.

        See `NervesHubLink.Client` for more information.
        \"\"\"

        use NervesHubLink.Client

        # Called to find out what to do when a firmware update is available.
        #
        # May return one of:
        #
        #   * `:apply` - download and apply the update right now
        #   * `:ignore` - don't download and apply this update
        #   * `{:ignore, reason}` - the same, with a reason that is sent to NervesHub
        #   * `{:reschedule, timeout}` - call this function again in `timeout`
        #     milliseconds
        #   * `{:reschedule, minutes, reason}` - call this function again in
        #     `minutes` minutes (not milliseconds), with a reason that is sent to
        #     NervesHub
        #
        # The default applies the update, unless it is the firmware that is
        # already running.
        @impl NervesHubLink.Client
        def update_available(update_info) do
          super(update_info)
        end

        # Called when an archive is available for download.
        #
        # May return `:download`, `:ignore` or `{:reschedule, timeout}` to be
        # called again in `timeout` milliseconds.
        #
        # The default logs and returns `:ignore`.
        @impl NervesHubLink.Client
        def archive_available(archive_info) do
          super(archive_info)
        end

        # Called when an archive has been downloaded to `file_path`, for the
        # application to do something with. Returns `:ok`.
        #
        # The default logs.
        @impl NervesHubLink.Client
        def archive_ready(archive_info, file_path) do
          super(archive_info, file_path)
        end

        # Called with firmware update progress and results, one of:
        #
        #   * `{:progress, percent}`
        #   * `{:ok, status, message}`
        #   * `{:warning, code, message}`
        #   * `{:error, code, message}`
        #
        # The return value is not checked. The default logs.
        @impl NervesHubLink.Client
        def handle_fwup_message(fwup_message) do
          super(fwup_message)
        end

        # Called when downloading a firmware update fails.
        #
        # The return value is not checked. The default logs.
        @impl NervesHubLink.Client
        def handle_error(error) do
          super(error)
        end

        # Called when NervesHub asks the device to identify itself, for example
        # by blinking an LED. Returns `:ok`.
        #
        # The default logs.
        @impl NervesHubLink.Client
        def identify() do
          super()
        end

        # Called when the socket disconnected, before reconnecting.
        #
        # Returns a list of delays in milliseconds to use for the reconnect
        # attempts, or `nil` to have NervesHubLink calculate random backoffs.
        #
        # The default returns `reconnect_after_msec` from
        # `config :nerves_hub_link, :socket`, which is `nil` when it isn't set.
        @impl NervesHubLink.Client
        def reconnect_backoff() do
          super()
        end

        # These callbacks are optional and have no implementation to override.
        # NervesHubLink does what is described when they aren't defined:
        #
        #   * `connected/0` - called when the connection to NervesHub has been
        #     established. The return value is not checked.
        #   * `reboot/0` - called to reboot the device when a firmware update
        #     completes, instead of `Nerves.Runtime.reboot/0`. It is critical
        #     that a reboot does happen.
        #   * `firmware_validated?/0` - returns whether the running firmware has
        #     been validated, instead of `Nerves.Runtime.firmware_valid?/0`.
        #   * `firmware_auto_revert_detected?/0` - returns whether the device
        #     just reverted to its previous firmware, instead of the check in
        #     `NervesHubLink.Client.firmware_auto_revert_detected?/0`.
      end
      """
    end
  end
else
  defmodule Mix.Tasks.NervesHubLink.Gen.Client do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    @spec run([String.t()]) :: no_return()
    def run(_argv) do
      Mix.shell().error("""
      The task 'nerves_hub_link.gen.client' requires igniter. Please install igniter and try again.

      For more information, see: https://igniter.hexdocs.pm/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
