# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions do
  @moduledoc """
  Extensions are a mechanism for transmitting messages for non-critical
  functionality over the existing NervesHub Socket. An extension will only
  attach if the server-side requests it from the device to ensure it will not
  disrupt regular operation.

  This module provides a behaviour with a macro to use for implementing an
  Extension.

  Extensions are started as separate GenServers under a DynamicSupervisor and
  any messages namespaced for a specific extension will be forwarded to that
  extension's GenServer.
  """

  use GenServer

  alias NervesHubLink.ExtensionsSupervisor
  alias NervesHubLink.Socket

  require Logger

  # `NervesHubLink.Extensions.Logging` is deliberately absent while it is in
  # early release. See `guides/extensions.md` for how to opt in.
  @default_extension_modules [
                               NervesHubLink.Extensions.Geo,
                               NervesHubLink.Extensions.Health,
                               NervesHubLink.Extensions.NetworkIdentity
                             ] ++
                               if(Code.ensure_loaded?(ExPTY),
                                 do: [NervesHubLink.Extensions.LocalShell],
                                 else: []
                               )

  @doc """
  Invoked when routing an Extension event

  Behaves the same as `c:GenServer.handle_info/2`
  """
  @callback handle_event(String.t(), map(), state :: term()) ::
              {:noreply, new_state}
              | {:noreply, new_state,
                 timeout() | :hibernate | {:continue, continue_arg :: term()}}
              | {:stop, reason :: term(), new_state}
            when new_state: term()

  @doc """
  Detach specified extensions

  Also supports `:all` as an argument for cases NervesHubLink
  may want to detach all of them at once
  """
  @spec detach(String.t() | [String.t()] | :all) :: :ok
  def detach(extension) when is_binary(extension), do: detach([extension])

  def detach(extensions) when is_list(extensions) or extensions == :all do
    GenServer.cast(__MODULE__, {:detach, extensions})
  end

  def detach(extensions), do: ignore_unusable_request("detach", extensions)

  @doc """
  Attach specified extensions
  """
  @spec attach(String.t() | [String.t()] | :all) :: :ok
  def attach(extension) when is_binary(extension), do: attach([extension])

  def attach(extensions) when is_list(extensions) or extensions == :all do
    GenServer.cast(__MODULE__, {:attach, extensions})
  end

  def attach(extensions), do: ignore_unusable_request("attach", extensions)

  # Extensions carry non-critical functionality and must not disrupt the rest of
  # the socket, so a request naming something other than extensions - notably a
  # join reply that isn't the list of names expected here - is logged and
  # dropped rather than raised back at the caller.
  defp ignore_unusable_request(action, extensions) do
    Logger.warning(
      "[NervesHubLink.Extensions] ignoring request to #{action} #{inspect(extensions)}"
    )

    :ok
  end

  @doc """
  List extensions currently available
  """
  @spec list() :: [
          %{
            String.t() => %{
              attached?: boolean(),
              attach_ref: String.t(),
              module: module(),
              version: boolean()
            }
          }
        ]
  def list(), do: GenServer.call(__MODULE__, :list)

  @doc """
  What to offer on the extensions join, given what the platform says it has.

  The platform sends its side in `extensions:get`, as `%{name => versions}`.
  This picks, for each extension both sides have, the version to declare, and
  returns the `%{name => version}` map the join carries.

  Pass `nil` when the server asked without naming anything, which is what every
  NervesHub does until it learns to advertise. It still serves the versions it
  always did, so everything is offered at the version this client implements
  rather than nothing being offered at all.

  Nothing is offered unless the server asks. Joining the extensions topic
  uninvited would be the device deciding it should be reporting, and that
  decision is the platform's.

  An extension the platform did not name is left out. It either does not
  implement it or has it switched off, and either way there is nothing to
  attach.

  > #### One version per extension {: .info}
  >
  > This client implements exactly one version of each extension, so choosing
  > is only ever a question of whether the platform has that one. Giving an
  > extension a second version means keying the registry by name *and* version
  > rather than by name alone, since `find_extensions/0` would otherwise keep
  > whichever module it saw last.
  """
  @spec offer(%{String.t() => [String.t()]} | nil) :: %{String.t() => String.t()}
  def offer(advertisement) do
    GenServer.call(__MODULE__, {:offer, advertisement})
  end

  @spec handle_event(String.t(), map()) :: :ok
  def handle_event(event, message) do
    GenServer.cast(__MODULE__, {:handle_event, event, message})
  end

  # The best version both sides have, most preferred first, matched as strings.
  # There is no version arithmetic to do here: the platform has already said
  # what it has, and asking a device to compare semver would mean a parser on
  # every client for a question already answered.
  defp choose(versions, advertisement, name) when is_map(advertisement) do
    case advertisement[name] do
      advertised when is_list(advertised) ->
        versions
        |> Enum.sort_by(&parsed/1, {:desc, Version})
        |> Enum.find(&(&1 in advertised))

      _not_advertised ->
        nil
    end
  end

  # No advertisement, or one this client cannot read. A NervesHub that names
  # nothing still serves the versions it always did, so the oldest is offered:
  # it is the one such a platform is sure to have.
  defp choose(versions, _advertisement, _name) do
    versions |> Enum.sort_by(&parsed/1, {:asc, Version}) |> List.first()
  end

  defp parsed(version) do
    case Version.parse(version) do
      {:ok, parsed} -> parsed
      :error -> Version.parse!("0.0.0")
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{extensions: find_extensions()}}
  end

  @doc """
  The extension modules this device is configured with.

  The configured list replaces the defaults rather than adding to them, which
  is what makes this worth asking for rather than reading the config directly.
  """
  @spec configured_modules() :: [module()]
  def configured_modules() do
    Application.get_env(:nerves_hub_link, :extension_modules, @default_extension_modules)
    |> Enum.flat_map(&siblings/1)
    |> Enum.uniq()
  end

  # An extension implemented at more than one version names all of them, so
  # configuring one is configuring the extension. Otherwise a device would have
  # to list every version of `logging` by hand and would silently get no
  # logging at all from a platform that has a version it did not think to name.
  defp siblings(mod) do
    _ = Code.ensure_loaded(mod)

    if function_exported?(mod, :__versions__, 0), do: mod.__versions__(), else: [mod]
  end

  defp find_extensions() do
    modules = configured_modules()

    Enum.each(modules, &Code.ensure_loaded/1)

    for mod <- modules,
        function_exported?(mod, :module_info, 1),
        {:behaviour, behaviours} <- mod.module_info(:attributes),
        __MODULE__ in behaviours,
        reduce: %{} do
      extensions ->
        # Keyed by name *and* version. One extension can have more than one
        # version implemented at once -- `logging` does, and 0.0.1 and 0.1.0 are
        # not the same conversation -- so keeping only whichever module was
        # found last would let load order decide what a device offers.
        name = mod.__name__()
        entry = Map.get(extensions, name, new_entry())
        versions = Map.put(entry.versions, to_string(mod.__version__()), mod)

        Map.put(extensions, name, %{entry | versions: versions} |> default_to_oldest())
    end
  end

  defp new_entry() do
    %{versions: %{}, module: nil, version: nil, attached?: false, attach_ref: nil}
  end

  # What an extension resolves to before anything has been negotiated: the
  # oldest version this device implements. `attach/1` called by hand has no
  # advertisement to go on, and the oldest is the one a platform is sure to
  # have. The newest would be a device guessing that the far end is current,
  # and being wrong about it silently.
  defp default_to_oldest(entry) do
    version =
      entry.versions |> Map.keys() |> Enum.sort_by(&parsed/1, {:asc, Version}) |> List.first()

    %{entry | version: version, module: entry.versions[version]}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, find_extensions(), state}
  end

  def handle_call({:offer, advertisement}, _from, state) do
    extensions = find_extensions()

    chosen =
      for {name, %{versions: versions}} <- extensions,
          version = choose(Map.keys(versions), advertisement, name),
          into: %{},
          do: {name, version}

    # Remembered so that the attach that follows starts the version that was
    # offered. A device that offered 0.0.1 and then attached 0.1.0 would be
    # talking a language the platform said it does not have.
    extensions =
      for {name, entry} <- extensions, into: %{} do
        case chosen[name] do
          nil -> {name, entry}
          version -> {name, %{entry | version: version, module: entry.versions[version]}}
        end
      end

    {:reply, chosen, %{state | extensions: extensions}}
  end

  def handle_call({:push, extension, event, payload}, _from, state) do
    # This serves as the gatekeeper for the socket and prevents
    # extension messages that may still be trying to send when they
    # have been detached and are not wanted over the socket
    result =
      if state.extensions[extension][:attached?] == true do
        scoped_event =
          if String.starts_with?(event, "#{extension}:"),
            do: event,
            else: "#{extension}:#{event}"

        push_to_socket(scoped_event, payload)
      else
        {:error, :detached}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:detach, extensions}, state) do
    state =
      for {_, pid, _, [module]} <-
            DynamicSupervisor.which_children(ExtensionsSupervisor),
          {extension, %{attach_ref: ref, module: ^module}} <- state.extensions,
          extensions == :all or extension in extensions or ref in extensions,
          reduce: state do
        acc ->
          # Ignore since either :ok, or {:error, :not_found}
          _ = DynamicSupervisor.terminate_child(ExtensionsSupervisor, pid)
          _ = Socket.push_extensions_message("#{extension}:detached", %{})
          put_in(acc.extensions[extension][:attached?], false)
      end

    {:noreply, state}
  end

  def handle_cast({:attach, extensions}, state) do
    extensions = if extensions == :all, do: Map.keys(state.extensions), else: extensions

    state =
      for extension <- extensions, reduce: state do
        acc ->
          with mod when not is_nil(mod) <- state.extensions[extension][:module],
               :ok <- start_extension(mod),
               {:ok, ref} <- Socket.push_extensions_message("#{extension}:attached", %{}) do
            update_in(acc.extensions[extension], &%{&1 | attached?: true, attach_ref: ref})
          else
            error ->
              reason = extension_message_from_error(error)
              _ = Socket.push_extensions_message("#{extension}:error", %{reason: reason})

              Logger.warning(
                "[NervesHubLink.Extensions] failed to start #{extension}: #{inspect(error)}"
              )

              acc
          end
      end

    {:noreply, state}
  end

  def handle_cast({:handle_event, event, payload}, state) when event in ["attach", "detach"] do
    extensions =
      case payload["extensions"] do
        "all" ->
          :all

        extensions when is_list(extensions) ->
          extensions

        feat when is_binary(feat) ->
          [feat]

        unknown ->
          Logger.warning(
            "[NervesHubLink.Extensions] missing extensions to #{event}: Got #{inspect(unknown)}"
          )

          []
      end

    handle_cast({String.to_existing_atom(event), extensions}, state)
  end

  def handle_cast({:handle_event, event, payload}, state) do
    delivered? =
      case String.split(event, ":", parts: 2) do
        [extension, event] ->
          case state.extensions[extension] do
            %{module: module} ->
              try do
                _ = send(module, {:__extension_event__, event, payload})
                true
              rescue
                error ->
                  Logger.error(
                    "[NervesHubLink.Extensions] Error handling event `#{inspect(event)}` with payload `#{inspect(payload)}`: #{inspect(error)}"
                  )

                  false
              end

            _ ->
              false
          end

        _ ->
          false
      end

    if not delivered? do
      # Event was unhandled. Maybe report it to NH?
      Logger.warning(
        "[NervesHubLink.Extensions] Unhandled event: #{inspect(event)} - #{inspect(payload)}"
      )
    end

    {:noreply, state}
  end

  # The socket reports an unjoined topic itself, so there's no need to ask it
  # separately whether it is connected - that only doubles the round trips and
  # leaves a window between the answer and the push. The socket isn't running at
  # all when `connect: false`, which a push has to survive rather than take this
  # process down with it.
  defp push_to_socket(event, payload) do
    Socket.push_extensions_message(event, payload)
  catch
    :exit, {:noproc, _} -> {:error, :socket_not_running}
  end

  defp start_extension(extension_module) do
    result = DynamicSupervisor.start_child(ExtensionsSupervisor, extension_module)

    case result do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      error -> error
    end
  end

  defp extension_message_from_error(error),
    do: if(error, do: "start_failure", else: "unknown_extension")

  defmacro __using__(opts) do
    name = opts[:name] || raise "Missing required extension arg: name"
    version = opts[:version] || raise "Missing required extension arg: version"
    # Every module implementing this extension, when there is more than one
    # version of it. Naming any of them configures all of them. Decided here
    # rather than in the generated function, which would leave one arm of a
    # `case` that can never be taken.
    versions = opts[:versions] || quote(do: [__MODULE__])

    quote location: :keep do
      use GenServer
      @behaviour NervesHubLink.Extensions

      def __name__(), do: unquote(name)
      def __version__(), do: unquote(version)

      @doc false
      def __versions__(), do: unquote(versions)

      # Re-implemented the included `child_spec/1` function from `use GenServer` so
      # that `@doc false` can be used to hide `child_spec/1` from the generated docs.
      @doc false
      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, [])
      end

      @doc false
      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc false
      @spec push(String.t(), map()) ::
              {:ok, Slipstream.push_reference()} | {:error, reason :: :detached | term()}
      def push(event, payload) do
        GenServer.call(NervesHubLink.Extensions, {:push, __name__(), event, payload})
      end

      @impl GenServer
      def handle_info({:__extension_event__, event, payload}, state) do
        handle_event(event, payload, state)
      end
    end
  end
end
