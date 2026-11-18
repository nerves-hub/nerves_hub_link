# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
# What the socket costs, measured the same way on either side of the
# Slipstream removal.
#
#   MIX_ENV=test mix run bench/socket_bench.exs
#
# `MIX_ENV=test` is for `bandit`, which is a test-only dependency on both
# branches. The server below speaks just enough of the Phoenix channel
# protocol - v2 and v1, since which one is asked for is the client's business -
# to answer a join and a heartbeat, and to count what it is sent.
#
# Reductions are the headline rather than wall time: they count work actually
# done, and they do not move with what else the machine is doing.
defmodule Bench do
  @moduledoc false

  @pushes 2_000
  @inbound 2_000
  @chunk 250

  # Processes started by the harness rather than by the library.
  @harness_prefixes ["Bandit", "ThousandIsland", "Plug", "Bench"]

  defmodule Server do
    @moduledoc false

    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      upgrade_adapter(conn, :websocket, {__MODULE__.Handler, [], []})
    end

    defmodule Handler do
      @moduledoc false

      @behaviour WebSock

      @impl WebSock
      def init(_opts) do
        :persistent_term.put({Bench, :server}, self())

        {:ok, %{}}
      end

      @impl WebSock
      def handle_in({payload, opcode: :text}, state) do
        :counters.add(:persistent_term.get({Bench, :frames}), 1, 1)

        case Jason.decode(payload) do
          # The v2 protocol: a five element array.
          {:ok, [join_ref, ref, topic, event, _params]} ->
            note_protocol(:v2)

            if event in ["phx_join", "heartbeat"] do
              {:push, v2_reply(join_ref, ref, topic), state}
            else
              {:ok, state}
            end

          # The v1 protocol: an object.
          {:ok, %{"topic" => topic, "event" => event, "ref" => ref}} ->
            note_protocol(:v1)

            if event in ["phx_join", "heartbeat"] do
              {:push, v1_reply(topic, ref), state}
            else
              {:ok, state}
            end

          _ ->
            {:ok, state}
        end
      end

      def handle_in(_frame, state), do: {:ok, state}

      @impl WebSock
      def handle_control(_frame, state), do: {:ok, state}

      @impl WebSock
      def handle_info({:blast, frames}, state), do: {:push, frames, state}

      def handle_info(_message, state), do: {:ok, state}

      @impl WebSock
      def terminate(_reason, _state), do: :ok

      # Writing a persistent_term forces a global GC scan, so this is written
      # once and read every other time.
      defp note_protocol(protocol) do
        if :persistent_term.get({Bench, :protocol}, nil) == nil do
          :persistent_term.put({Bench, :protocol}, protocol)
        end

        :ok
      end

      defp v2_reply(join_ref, ref, topic) do
        {:text,
         Jason.encode!([
           join_ref,
           ref,
           topic,
           "phx_reply",
           %{"status" => "ok", "response" => %{}}
         ])}
      end

      defp v1_reply(topic, ref) do
        {:text,
         Jason.encode!(%{
           "topic" => topic,
           "event" => "phx_reply",
           "ref" => ref,
           "payload" => %{"status" => "ok", "response" => %{}}
         })}
      end
    end
  end

  defmodule UpdateManagerStub do
    @moduledoc false

    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, name: NervesHubLink.UpdateManager)
    end

    @impl GenServer
    def init(:ok), do: {:ok, :ok}

    @impl GenServer
    def handle_call(:currently_downloading_uuid, _from, state), do: {:reply, nil, state}

    def handle_call(_message, _from, state), do: {:reply, nil, state}
  end

  def run() do
    :persistent_term.put({Bench, :frames}, :counters.new(1, []))

    {:ok, _stub} = UpdateManagerStub.start_link([])

    port = free_port()

    {:ok, _bandit} =
      Bandit.start_link(plug: Server, scheme: :http, port: port, startup_log: false)

    others = MapSet.new(Process.list())
    :erlang.garbage_collect()
    memory_before = :erlang.memory(:total)

    started_at = System.monotonic_time(:microsecond)
    {:ok, socket} = NervesHubLink.Socket.start_link(config(port), name: Bench.Socket)
    wait_until("the socket to connect", fn -> NervesHubLink.socket_connected?(socket) end)
    connect_usec = System.monotonic_time(:microsecond) - started_at

    # The join is the first thing written after the upgrade; wait for the
    # server to have it so the connection is settled before anything is timed.
    wait_until("the device topic to join", fn -> frames() >= 1 end)
    Process.sleep(200)

    device = device_processes(others)

    outbound = measure_outbound(socket, device)
    inbound = measure_inbound(socket, device)

    # What a chatty connection leaves behind matters on a device with little
    # RAM, so the memory is read before anything is collected as well as after.
    loaded_memory = total_memory(device)

    Enum.each(device, &:erlang.garbage_collect/1)
    Process.sleep(50)

    report(%{
      loaded_memory: loaded_memory,
      protocol: :persistent_term.get({Bench, :protocol}, :unknown),
      connect_usec: connect_usec,
      memory_delta: :erlang.memory(:total) - memory_before,
      device: device,
      outbound: outbound,
      inbound: inbound
    })
  end

  # Device to server: `send_update_status/2` is a cast, so the whole run is
  # queued and then waited for at the server.
  defp measure_outbound(socket, device) do
    base = frames()
    reductions_before = reductions(device)
    started_at = System.monotonic_time(:microsecond)

    for i <- 1..@pushes, do: NervesHubLink.send_update_status(socket, {:downloading, i})

    wait_until("#{@pushes} pushes to arrive", fn -> frames() - base >= @pushes end)

    %{
      usec: System.monotonic_time(:microsecond) - started_at,
      reductions: reductions(device) - reductions_before
    }
  end

  # Server to device: `update_mode` is cheap, and the mode it leaves behind is
  # readable, so the last frame of the run is what says the device is done.
  # The read is a call, which queues behind the run rather than polling it.
  defp measure_inbound(socket, device) do
    server = :persistent_term.get({Bench, :server})

    frames =
      for i <- 1..@inbound do
        update_mode_frame(if rem(i, 2) == 0, do: "automatic", else: "device_managed")
      end

    # Start from the mode the run does not end on, so waiting for `:automatic`
    # cannot pass on state left over from the connect.
    send(server, {:blast, [update_mode_frame("device_managed")]})

    wait_until("the mode to start from", fn ->
      NervesHubLink.update_mode(socket) == :device_managed
    end)

    reductions_before = reductions(device)
    started_at = System.monotonic_time(:microsecond)

    frames
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&send(server, {:blast, &1}))

    wait_until("#{@inbound} messages to be handled", fn ->
      NervesHubLink.update_mode(socket) == :automatic
    end)

    %{
      usec: System.monotonic_time(:microsecond) - started_at,
      reductions: reductions(device) - reductions_before
    }
  end

  defp update_mode_frame(mode) do
    {:text,
     Jason.encode!([
       nil,
       nil,
       "device",
       "update_mode",
       %{"mode" => mode, "managed_updates_allowed" => true}
     ])}
  end

  defp device_processes(others) do
    Process.list()
    |> Enum.reject(&MapSet.member?(others, &1))
    |> Enum.reject(&harness?/1)
  end

  defp harness?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        name =
          case Keyword.get(dictionary, :"$initial_call") do
            {module, _function, _arity} -> inspect(module)
            _ -> ""
          end

        Enum.any?(@harness_prefixes, &String.starts_with?(name, &1))

      nil ->
        true
    end
  end

  defp reductions(pids) do
    Enum.reduce(pids, 0, fn pid, total ->
      case Process.info(pid, :reductions) do
        {:reductions, reductions} -> total + reductions
        nil -> total
      end
    end)
  end

  defp frames(), do: :counters.get(:persistent_term.get({Bench, :frames}), 1)

  defp config(port) do
    data_path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data_path)

    struct(NervesHubLink.Configurator.Config,
      compress: false,
      connect_wait_for_network: false,
      data_path: data_path,
      heartbeat_interval_msec: 30_000,
      params: %{"device_api_version" => "2.4.0"},
      rejoin_after: [1_000],
      remote_iex: false,
      socket: [
        url: URI.parse("ws://127.0.0.1:#{port}/socket/websocket"),
        reconnect_after_msec: [1_000]
      ],
      ssl: []
    )
  end

  defp free_port() do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    port
  end

  defp wait_until(what, fun, remaining \\ 10_000)

  defp wait_until(what, _fun, remaining) when remaining <= 0 do
    raise "timed out waiting for #{what}"
  end

  defp wait_until(what, fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(what, fun, remaining - 20)
    end
  end

  defp report(result) do
    slipstream = Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == :slipstream))

    IO.puts("")
    IO.puts("nerves_hub_link socket benchmark")
    IO.puts("  version        : #{Application.spec(:nerves_hub_link, :vsn)}")
    IO.puts("  slipstream     : #{if slipstream, do: "loaded", else: "not loaded"}")
    IO.puts("  protocol seen  : #{result.protocol}")
    IO.puts("  elixir/otp     : #{System.version()} / #{System.otp_release()}")
    IO.puts("")
    IO.puts("connect and join")
    IO.puts("  time to connected : #{fmt_ms(result.connect_usec)} ms")
    IO.puts("")
    IO.puts("processes the socket runs (#{length(result.device)})")

    for pid <- result.device do
      IO.puts(
        "  #{inspect(pid)}  #{String.pad_trailing(initial_call(pid), 46)} " <>
          "#{pad(process_memory(pid))} bytes  #{pad(mailbox(pid))} queued"
      )
    end

    IO.puts("  after 4000 messages  : #{pad(result.loaded_memory)} bytes")
    IO.puts("  collected            : #{pad(total_memory(result.device))} bytes")
    IO.puts("  beam total delta     : #{pad(result.memory_delta)} bytes")
    IO.puts("")
    IO.puts("#{@pushes} pushes, device to server")
    IO.puts("  reductions : #{pad(result.outbound.reductions)}")
    IO.puts("  per push   : #{pad(div(result.outbound.reductions, @pushes))}")
    IO.puts("  wall       : #{fmt_ms(result.outbound.usec)} ms")
    IO.puts("")
    IO.puts("#{@inbound} messages, server to device")
    IO.puts("  reductions : #{pad(result.inbound.reductions)}")
    IO.puts("  per message: #{pad(div(result.inbound.reductions, @inbound))}")
    IO.puts("  wall       : #{fmt_ms(result.inbound.usec)} ms")
    IO.puts("")
  end

  defp initial_call(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case Keyword.get(dictionary, :"$initial_call") do
          {module, function, arity} -> "#{inspect(module)}.#{function}/#{arity}"
          _ -> "?"
        end

      nil ->
        "(gone)"
    end
  end

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, memory} -> memory
      nil -> 0
    end
  end

  defp mailbox(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> 0
    end
  end

  defp total_memory(pids), do: Enum.reduce(pids, 0, &(process_memory(&1) + &2))

  defp pad(number) do
    number
    |> to_string()
    |> String.pad_leading(9)
  end

  defp fmt_ms(usec), do: :erlang.float_to_binary(usec / 1000, decimals: 1)
end

Bench.run()
