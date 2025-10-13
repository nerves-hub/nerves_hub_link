# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
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

  @default_extension_modules [
    NervesHubLink.Extensions.Health,
    NervesHubLink.Extensions.Geo,
    NervesHubLink.Extensions.LocalShell
  ]

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

  def detach(extensions) do
    GenServer.cast(__MODULE__, {:detach, extensions})
  end

  @doc """
  Attach specified extensions
  """
  @spec attach(String.t() | [String.t()] | :all) :: :ok
  def attach(extension) when is_binary(extension), do: attach([extension])

  def attach(extensions) when is_list(extensions) do
    GenServer.cast(__MODULE__, {:attach, extensions})
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

  @spec handle_event(String.t(), map()) :: :ok
  def handle_event(event, message) do
    GenServer.cast(__MODULE__, {:handle_event, event, message})
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{extensions: find_extensions()}}
  end

  defp find_extensions() do
    modules =
      Application.get_env(:nerves_hub_link, :extension_modules, @default_extension_modules)

    Enum.each(modules, &Code.ensure_loaded/1)

    for mod <- modules,
        function_exported?(mod, :module_info, 1),
        {:behaviour, behaviours} <- mod.module_info(:attributes),
        __MODULE__ in behaviours,
        into: %{} do
      {mod.__name__(),
       %{module: mod, version: mod.__version__(), attached?: false, attach_ref: nil}}
    end
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, find_extensions(), state}
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

        Socket.push("extensions", scoped_event, payload)
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
          _ = Socket.push("extensions", "#{extension}:detached", %{})
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
               {:ok, ref} <- Socket.push("extensions", "#{extension}:attached", %{}) do
            update_in(acc.extensions[extension], &%{&1 | attached?: true, attach_ref: ref})
          else
            error ->
              reason = if error, do: "start_failure", else: "unknown_extension"
              _ = Socket.push("extensions", "#{extension}:error", %{reason: reason})

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
    results =
      case String.split(event, ":", parts: 2) do
        [extension, event] ->
          case state.extensions[extension] do
            %{module: module} ->
              send(module, {:__extension_event__, event, payload})

            _ ->
              nil
          end

        _ ->
          nil
      end

    if results == [] do
      # Event was unhandled. Maybe report it to NH?
      Logger.warning(
        "[NervesHubLink.Extensions] Unhandled event: #{inspect(event)} - #{inspect(payload)}"
      )
    end

    {:noreply, state}
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

  defmacro __using__(opts) do
    name = opts[:name] || raise "Missing required extension arg: name"
    version = opts[:version] || raise "Missing required extension arg: version"

    quote location: :keep do
      use GenServer
      @behaviour NervesHubLink.Extensions

      def __name__(), do: unquote(name)
      def __version__(), do: unquote(version)

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
