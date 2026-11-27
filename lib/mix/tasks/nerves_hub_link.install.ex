# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.NervesHubLink.Install.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc() do
    "Installs nerves_hub_link in your Nerves project."
  end

  @spec example() :: String.t()
  def example() do
    "mix igniter.install nerves_hub_link --nerves-hub-host devices.example.com"
  end

  @spec long_doc() :: String.t()
  def long_doc() do
    """
    #{short_doc()}

    Configures the device to connect to a NervesHub server. The configuration
    is written to `config/target.exs` when it exists, as it only makes sense on
    a device, and `config/host.exs` is told not to connect. Nothing that is
    already configured is overwritten.

    No secret is ever written to a file. With shared secret authentication the
    product key and secret are read from the `NERVES_HUB_PRODUCT_KEY` and
    `NERVES_HUB_PRODUCT_SECRET` environment variables when the firmware is
    built.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--nerves-hub-host` - The host devices connect to, e.g.
      `devices.example.com` or `devices.example.com:4001`. Defaults to
      `devices.nervescloud.com`, the device endpoint of NervesCloud.
    * `--nerves-hub-auth` - How the device authenticates. When it isn't
      passed, you're asked. If there's nobody to ask (`--yes`, CI or other
      non-interactive runs), `shared-secret` is used. A project that already
      has authentication set up isn't asked again. One of:
        * `shared-secret` - a product key and secret, read from the
          environment when the firmware is built. For hobby and R&D projects.
        * `nerves-key` - certificates from a NervesKey. Adds the `nerves_key`
          dependency.
        * `tpm` - key and certificate from a TPM. Adds the `tpm` dependency.
        * `local-cert` - a certificate and key from the file system, using
          `NervesHubLink.Configurator.LocalCertKey`.
    * `--nerves-hub-remote-iex` - Enable the remote IEx console, which is off
      by default.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NervesHubLink.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Project.Config
    alias Igniter.Project.Deps

    @default_host "devices.nervescloud.com"
    @product_key_env "NERVES_HUB_PRODUCT_KEY"
    @product_secret_env "NERVES_HUB_PRODUCT_SECRET"
    @auth_methods ["shared-secret", "nerves-key", "tpm", "local-cert"]
    @default_auth "shared-secret"
    @auth_descriptions %{
      "shared-secret" => "shared-secret - a product key and secret (hobby and R&D projects)",
      "nerves-key" => "nerves-key - certificates from a NervesKey (ATECC608)",
      "tpm" => "tpm - key and certificate from a TPM",
      "local-cert" => "local-cert - a certificate and key on the device's file system"
    }

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :nerves_hub_link,
        example: __MODULE__.Docs.example(),
        schema: [
          nerves_hub_host: :string,
          nerves_hub_auth: :string,
          nerves_hub_remote_iex: :boolean
        ],
        # `:nerves_hub_auth` has no default here so that not passing it can
        # be told apart from asking for shared secrets.
        defaults: [
          nerves_hub_remote_iex: false
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      auth = igniter.args.options[:nerves_hub_auth] || choose_auth(igniter)

      if auth in @auth_methods do
        install(igniter, auth)
      else
        Igniter.add_issue(
          igniter,
          "Unknown --nerves-hub-auth #{inspect(auth)}. Expected one of: #{Enum.join(@auth_methods, ", ")}"
        )
      end
    end

    # Without `--nerves-hub-auth`, a project that's already set up keeps what
    # it has, the user is asked when there's someone to ask, and everything
    # else (`--yes`, CI, piped input) gets shared secrets.
    defp choose_auth(igniter) do
      cond do
        existing = existing_auth(igniter) -> existing
        interactive?(igniter) -> prompt_auth()
        true -> @default_auth
      end
    end

    defp existing_auth(igniter) do
      cond do
        configures?(igniter, :shared_secret) -> "shared-secret"
        Deps.has_dep?(igniter, :nerves_key) -> "nerves-key"
        Deps.has_dep?(igniter, :tpm) -> "tpm"
        configures?(igniter, :configurator) -> "local-cert"
        true -> nil
      end
    end

    defp configures?(igniter, key) do
      Enum.any?(["target.exs", "config.exs"], fn file ->
        Igniter.exists?(igniter, Path.join("config", file)) and
          Config.configures_key?(igniter, file, :nerves_hub_link, [key])
      end)
    end

    # Tests set the assign since they never have a terminal
    defp interactive?(igniter) do
      yes? = igniter.args.options[:yes] == true or "--yes" in igniter.args.argv_flags

      case igniter.assigns[:nerves_hub_link_interactive?] do
        nil -> not yes? and igniter.assigns[:test_mode?] != true and Igniter.Mix.Task.tty?()
        interactive? -> interactive? and not yes?
      end
    end

    defp prompt_auth() do
      Igniter.Util.IO.select(
        "How should devices authenticate with NervesHub?",
        @auth_methods,
        default: @default_auth,
        display: &Map.fetch!(@auth_descriptions, &1)
      )
    end

    defp install(igniter, auth) do
      nerves? = Igniter.exists?(igniter, "config/target.exs")
      config_file = if nerves?, do: "target.exs", else: "config.exs"
      host = igniter.args.options[:nerves_hub_host]

      igniter
      |> Config.configure_new(config_file, :nerves_hub_link, [:host], host || @default_host)
      |> configure_auth(config_file, auth)
      |> configure_remote_iex(config_file)
      |> configure_host_build()
      |> non_nerves_notice(nerves?)
      |> host_notice(config_file, host)
      |> auth_notice(config_file, auth)
      |> Igniter.add_notice(firmware_notice())
    end

    defp configure_auth(igniter, config_file, "shared-secret") do
      # The values are read from the environment when the firmware is built so
      # that the secret never lands in a file that gets committed.
      Config.configure_new(
        igniter,
        config_file,
        :nerves_hub_link,
        [:shared_secret],
        {:code,
         Sourceror.parse_string!("""
         [
           product_key: System.get_env("#{@product_key_env}"),
           product_secret: System.get_env("#{@product_secret_env}")
         ]
         """)}
      )
    end

    defp configure_auth(igniter, _config_file, "nerves-key") do
      Deps.add_dep(igniter, {:nerves_key, "~> 1.2"}, on_exists: :skip)
    end

    defp configure_auth(igniter, _config_file, "tpm") do
      Deps.add_dep(igniter, {:tpm, "~> 0.2.0"}, on_exists: :skip)
    end

    defp configure_auth(igniter, config_file, "local-cert") do
      Config.configure_new(
        igniter,
        config_file,
        :nerves_hub_link,
        [:configurator],
        NervesHubLink.Configurator.LocalCertKey
      )
    end

    defp configure_remote_iex(igniter, config_file) do
      if igniter.args.options[:nerves_hub_remote_iex] do
        Config.configure_new(igniter, config_file, :nerves_hub_link, [:remote_iex], true)
      else
        igniter
      end
    end

    # There is no NervesHub to connect to when running on the host, and no
    # connection settings in `config/host.exs` to connect with.
    defp configure_host_build(igniter) do
      if Igniter.exists?(igniter, "config/host.exs") do
        Config.configure_new(igniter, "host.exs", :nerves_hub_link, [:connect], false)
      else
        igniter
      end
    end

    defp non_nerves_notice(igniter, true), do: igniter

    defp non_nerves_notice(igniter, false) do
      Igniter.add_notice(igniter, """
      nerves_hub_link: no `config/target.exs` was found, so the configuration
      went into `config/config.exs`. The defaults of `mix nerves_hub_link.install`
      are intended for Nerves projects, where they only apply to the device. Add
      `config :nerves_hub_link, connect: false` wherever a connection to
      NervesHub is not wanted, such as `config/test.exs`.
      """)
    end

    defp host_notice(igniter, _config_file, host) when is_binary(host), do: igniter

    defp host_notice(igniter, config_file, nil) do
      Igniter.add_notice(igniter, """
      nerves_hub_link: no `--nerves-hub-host` was given, so devices connect to
      NervesCloud (`host: "#{@default_host}"` in `config/#{config_file}`). If you
      run your own NervesHub server, replace it with the host that your server
      accepts device connections on.
      """)
    end

    defp auth_notice(igniter, config_file, "shared-secret") do
      Igniter.add_notice(igniter, """
      nerves_hub_link: shared secret authentication is set up in
      `config/#{config_file}`. No secret was written to it. Before building
      firmware:

        1. Create a Product in the NervesHub web UI, or with
           `mix nerves_hub.product create` from nerves_hub_cli.
        2. Generate a product key and secret in the Product's settings.
        3. Set both in the environment of every firmware build:

             export #{@product_key_env}=nhp_...
             export #{@product_secret_env}=...

      The values are read when the firmware is compiled. A build without them
      succeeds, but NervesHubLink then fails to start on the device, and
      neither does any application that depends on it. That includes this
      project's application.

      Shared secrets are meant for hobby and R&D projects. Device certificates
      are recommended for production (`--nerves-hub-auth nerves-key`, `tpm` or
      `local-cert`).
      """)
    end

    defp auth_notice(igniter, _config_file, "nerves-key") do
      Igniter.add_notice(igniter, """
      nerves_hub_link: NervesKey authentication is used whenever the
      `nerves_key` dependency is present, which has been added to `mix.exs`.
      Run `mix deps.get`. Remaining steps:

        1. Provision each NervesKey with a device certificate, see
           https://hexdocs.pm/nerves_key
        2. Register the signer CA certificate with NervesHub in the web UI, or
           with `mix nerves_hub.ca_certificate register my-signer.cert` from
           nerves_hub_cli.

      I2C bus 1 and the `:primary` certificate pair are used unless you set
      `config :nerves_hub_link, :nerves_key, i2c_bus: ..., certificate_pair: ...`.
      """)
    end

    defp auth_notice(igniter, _config_file, "tpm") do
      Igniter.add_notice(igniter, """
      nerves_hub_link: TPM authentication is used whenever the `tpm` dependency
      is present, which has been added to `mix.exs`. Run `mix deps.get`.
      Remaining steps:

        1. Provision each TPM with a device key and certificate.
        2. Register the signer CA certificate with NervesHub in the web UI, or
           with `mix nerves_hub.ca_certificate register my-signer.cert` from
           nerves_hub_cli.

      The defaults (`tpm_tis_spi`, key at `/data/.ssh/nerves_hub_link_key`,
      certificate at address `0x1000001`) can be changed with
      `config :nerves_hub_link, :tpm, probe_name: ..., key_path: ..., certificate_address: ...`.
      """)
    end

    defp auth_notice(igniter, config_file, "local-cert") do
      Igniter.add_notice(igniter, """
      nerves_hub_link: certificate authentication from the file system is set up
      in `config/#{config_file}`. No certificate or key was generated. Remaining
      steps:

        1. Create a certificate and key for each device and register it with
           NervesHub, see
           https://github.com/nerves-hub/nerves_hub_cli#initializing-devices
        2. Put them on the device at `/data/nerves_hub/cert.pem` and
           `/data/nerves_hub/key.pem`, or set `ssl: [certfile: ..., keyfile: ...]`
           under `config :nerves_hub_link`.
      """)
    end

    defp firmware_notice() do
      """
      nerves_hub_link: NervesHub only accepts signed firmware. This is not
      something the installer can do for you:

        1. Create a signing key with `mix nerves_hub.key create <name>` from
           nerves_hub_cli, or register an existing public key in the NervesHub
           web UI. Keep the private key out of the repository.
        2. Sign and upload each firmware, e.g.
           `mix nerves_hub.firmware publish --key <name>`.

      The device asks NervesHub for the public keys when it connects, so
      `fwup_public_keys` does not need configuring. Set it yourself to pin the
      keys in the firmware instead.

      Each device also needs a unique serial number, as that is how NervesHub
      identifies it.
      """
    end
  end
else
  defmodule Mix.Tasks.NervesHubLink.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    @spec run([String.t()]) :: no_return()
    def run(_argv) do
      Mix.shell().error("""
      The task 'nerves_hub_link.install' requires igniter. Please install igniter and try again.

      For more information, see: https://igniter.hexdocs.pm/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
