defmodule NervesHubLink.Features do
  use GenServer
  require Logger

  alias NervesHubLink.FeaturesSupervisor
  alias NervesHubLink.Socket

  @doc """
  Invoked when routing a Feature event

  Behaves the same as `c:GenServer.handle_info/2`
  """
  @callback handle_event(String.t(), map(), state :: term()) ::
              {:noreply, new_state}
              | {:noreply, new_state,
                 timeout() | :hibernate | {:continue, continue_arg :: term()}}
              | {:stop, reason :: term(), new_state}
            when new_state: term()

  @doc """
  Detach specified features

  Also supports `:all` as an argument for cases NervesHubLink
  may want to detach all of them at once
  """
  @spec detach(String.t() | [String.t()] | :all) :: :ok
  def detach(feature) when is_binary(feature), do: detach([feature])

  def detach(features) do
    GenServer.cast(__MODULE__, {:detach, features})
  end

  @doc """
  Attach specified features
  """
  @spec attach(String.t() | [String.t()] | :all) :: :ok
  def attach(feature) when is_binary(feature), do: attach([feature])

  def attach(features) when is_list(features) do
    GenServer.cast(__MODULE__, {:attach, features})
  end

  @doc """
  List features currently available
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

  def handle_event(event, message) do
    GenServer.cast(__MODULE__, {:handle_event, event, message})
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{features: find_features()}}
  end

  def find_features() do
    for mod <- Application.spec(:nerves_hub_link, :modules),
        Code.ensure_loaded?(mod),
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
    {:reply, state.features, state}
  end

  def handle_call({:push, feature, event, payload}, _from, state) do
    # This serves as the gatekeeper for the socket and prevents
    # feature messages that may still be trying to send when they
    # have been detached and are not wanted over the socket
    result =
      if state.features[feature][:attached?] == true do
        scoped_event =
          if not String.starts_with?(event, "#{feature}:"), do: "#{feature}:#{event}", else: event

        Socket.push("features", scoped_event, payload)
      else
        {:error, :detached}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:detach, features}, state) do
    state =
      for {_, pid, _, [module]} <-
            DynamicSupervisor.which_children(FeaturesSupervisor),
          {feature, %{attach_ref: ref, module: ^module}} <- state.features,
          features == :all or feature in features or ref in features,
          reduce: state do
        acc ->
          # Ignore since either :ok, or {:error, :not_found}
          _ = DynamicSupervisor.terminate_child(FeaturesSupervisor, pid)
          _ = Socket.push("features", "#{feature}:detached", %{})
          put_in(acc.features[feature][:attached?], false)
      end

    {:noreply, state}
  end

  def handle_cast({:attach, features}, state) do
    features = if features == :all, do: Map.keys(state.features), else: features

    state =
      for feature <- features, reduce: state do
        acc ->
          with mod when not is_nil(mod) <- state.features[feature][:module],
               :ok <- start_feature(mod),
               {:ok, ref} <- Socket.push("features", "#{feature}:attached", %{}) do
            update_in(acc.features[feature], &%{&1 | attached?: true, attach_ref: ref})
          else
            error ->
              reason = if error, do: "start_failure", else: "unknown_feature"
              _ = Socket.push("features", "#{feature}:error", %{reason: reason})

              Logger.warning(
                "[NervesHubLink.Features] failed to start #{feature}: #{inspect(error)}"
              )

              acc
          end
      end

    {:noreply, state}
  end

  def handle_cast({:handle_event, event, payload}, state) when event in ["attach", "detach"] do
    features =
      case payload["features"] do
        "all" ->
          :all

        features when is_list(features) ->
          features

        feat when is_binary(feat) ->
          [feat]

        unknown ->
          Logger.warning(
            "[NervesHubLink.Features] missing features to #{event}: Got #{inspect(unknown)}"
          )

          []
      end

    handle_cast({String.to_existing_atom(event), features}, state)
  end

  def handle_cast({:handle_event, event, payload}, state) do
    results =
      case String.split(event, ":", parts: 2) do
        [feature, event] ->
          case state.features[feature] do
            %{module: module} ->
              send(module, {:__feature_event__, event, payload})

            _ ->
              nil
          end

        _ ->
          nil
      end

    if results == [] do
      # Event was unhandled. Maybe report it to NH?
      Logger.warning(
        "[NervesHubLink.Features] Unhandled event: #{inspect(event)} - #{inspect(payload)}"
      )
    end

    {:noreply, state}
  end

  defp start_feature(feature_module) do
    result = DynamicSupervisor.start_child(FeaturesSupervisor, feature_module)

    case result do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      error -> error
    end
  end

  defmacro __using__(opts) do
    name = opts[:name] || raise "Missing required feature arg: name"
    version = opts[:version] || raise "Missing required feature arg: version"

    quote location: :keep do
      use GenServer
      @behaviour NervesHubLink.Features

      def __name__(), do: unquote(name)
      def __version__(), do: unquote(version)

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @spec push(String.t(), map()) ::
              {:ok, Slipstream.push_reference()} | {:error, reason :: :detached | term()}
      def push(event, payload) do
        GenServer.call(NervesHubLink.Features, {:push, __name__(), event, payload})
      end

      @impl GenServer
      def handle_info({:__feature_event__, event, payload}, state) do
        handle_event(event, payload, state)
      end
    end
  end
end
