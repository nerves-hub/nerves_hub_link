# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.LoggingTest.SocketStub do
  @moduledoc """
  Stands in for `NervesHubLink.Socket` and forwards extension pushes to the test.
  """

  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(test_pid) do
    GenServer.start_link(__MODULE__, test_pid, name: NervesHubLink.Socket)
  end

  @impl GenServer
  def init(test_pid), do: {:ok, test_pid}

  @impl GenServer
  def handle_call({:push, topic, event, payload}, _from, test_pid) do
    send(test_pid, {:pushed, topic, event, payload})
    {:reply, {:ok, make_ref()}, test_pid}
  end
end

defmodule NervesHubLink.Extensions.LoggingTest do
  @moduledoc """
  The logging extension installs a global `:logger` handler, so these run
  synchronously and take the handler back down on the way out.
  """

  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.Extensions.LoggingTest.SocketStub

  require Logger

  @handler_id :nerves_hub_link_logger_extension_handler

  setup do
    previous = Application.get_env(:nerves_hub_link, :logging)

    on_exit(fn ->
      if previous do
        Application.put_env(:nerves_hub_link, :logging, previous)
      else
        Application.delete_env(:nerves_hub_link, :logging)
      end

      _ = :logger.remove_handler(@handler_id)
    end)

    _ = start_supervised!({SocketStub, self()})
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(Extensions)

    :ok
  end

  describe "sending log lines" do
    setup :attach_logging

    test "an iolist message is sent as a single line of text" do
      Logger.info(["an ", "iolist ", "message"])

      assert_receive {:pushed, "extensions", "logging:send", payload}
      assert payload.message == "an iolist message"
      assert payload.level == :info
    end

    test "a binary message is sent unchanged" do
      Logger.info("a plain binary")

      assert_receive {:pushed, "extensions", "logging:send", %{message: "a plain binary"}}
    end

    test "an interpolated message is sent as text" do
      count = 2
      Logger.info("interpolated #{count}")

      assert_receive {:pushed, "extensions", "logging:send", %{message: "interpolated 2"}}
    end

    test "metadata is sent as strings" do
      Logger.info("with metadata")

      assert_receive {:pushed, "extensions", "logging:send",
                      %{message: "with metadata"} = payload}

      # Logger attaches pids, tuples and charlists, none of which survive being
      # put on the wire as themselves
      assert is_binary(payload.meta[:pid])
      assert is_binary(payload.meta[:mfa])
      assert Enum.all?(Map.values(payload.meta), &is_binary/1)
    end

    test "log events that aren't lines of text are ignored" do
      Logger.info(%{not: "a string"})

      refute_receive {:pushed, "extensions", "logging:send", _}, 100
    end
  end

  describe "log level" do
    test "levels below the configured one are not sent" do
      Application.put_env(:nerves_hub_link, :logging, level: :error)
      attach_logging(%{})

      Logger.info("this should stay on the device")
      Logger.error("this should be sent")

      assert_receive {:pushed, "extensions", "logging:send", %{level: :error}}
      refute_received {:pushed, "extensions", "logging:send", %{level: :info}}
    end

    test "debug lines are not sent by default" do
      attach_logging(%{})

      Logger.debug("chatty")
      Logger.info("worth sending")

      assert_receive {:pushed, "extensions", "logging:send", %{level: :info}}
      refute_received {:pushed, "extensions", "logging:send", %{level: :debug}}
    end
  end

  describe "the logger handler" do
    test "is installed while the extension is attached" do
      attach_logging(%{})

      assert {:ok, _config} = :logger.get_handler_config(@handler_id)
    end

    test "is removed when the extension is detached" do
      attach_logging(%{})

      :ok = Extensions.detach("logging")
      assert_receive {:pushed, "extensions", "logging:detached", %{}}

      assert {:error, {:not_found, @handler_id}} = :logger.get_handler_config(@handler_id)
    end

    test "stops sending once the extension is detached" do
      attach_logging(%{})

      :ok = Extensions.detach("logging")
      assert_receive {:pushed, "extensions", "logging:detached", %{}}

      Logger.error("nobody is listening")

      refute_receive {:pushed, "extensions", "logging:send", _}, 100
    end
  end

  defp attach_logging(_context \\ %{}) do
    :ok = Extensions.attach("logging")
    assert_receive {:pushed, "extensions", "logging:attached", %{}}
    :ok
  end
end
