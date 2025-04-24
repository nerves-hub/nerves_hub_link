# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UrlToFileTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Support.{
    HTTPErrorPlug,
    IdleTimeoutPlug,
    RangeRequestPlug,
    RedirectPlug,
    Utils,
    XRetryNumberPlug
  }

  alias NervesHubLink.Downloader.RetryConfig
  alias NervesHubLink.Downloader.UrlToFile

  @short_retry_args %RetryConfig{
    max_disconnects: 10,
    idle_timeout: 60_000,
    max_timeout: 3_600_000,
    time_between_retries: 10,
    worst_case_download_speed: 30_000
  }

  @failure_url "http://localhost:#{Utils.unique_port_number()}/this_should_fail"

  test "max_disconnects" do
    test_pid = self()
    handler_fun = &send(test_pid, &1)

    retry_args = RetryConfig.validate(max_disconnects: 2, time_between_retries: 1)

    uuid = Ecto.UUID.generate()
    Process.flag(:trap_exit, true)
    {:ok, download} = UrlToFile.start_download(uuid, @failure_url, handler_fun, retry_args)
    # should receive this one twice
    assert_receive {:error, :request_error}
    assert_receive {:error, :request_error}
    # then exit
    assert_receive {:EXIT, ^download, :max_disconnects_reached}
  end

  test "max_timeout" do
    test_pid = self()
    handler_fun = &send(test_pid, &1)

    retry_args = RetryConfig.validate(max_timeout: 10)

    uuid = Ecto.UUID.generate()
    Process.flag(:trap_exit, true)
    {:ok, download} = UrlToFile.start_download(uuid, @failure_url, handler_fun, retry_args)
    assert_receive {:error, :max_timeout_reached}
    assert_receive {:EXIT, ^download, :max_timeout_reached}
  end

  describe "idle timeout" do
    setup do
      {:ok, pid} = Bandit.start_link(plug: IdleTimeoutPlug, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      {:ok, [url: "http://localhost:#{port}/test"]}
    end

    test "idle_timeout causes retry", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)

      retry_args =
        RetryConfig.validate(
          idle_timeout: 100,
          time_between_retries: 10
        )

      uuid = Ecto.UUID.generate()
      {:ok, _download} = UrlToFile.start_download(uuid, url, handler_fun, retry_args)
      assert_receive {:error, :idle_timeout}, 1000
      assert_receive {:download_progress, 100}
      assert_receive {:complete, path}
      assert {:ok, %{type: :regular}} = File.stat(path)
    end
  end

  describe "http error" do
    setup do
      {:ok, pid} = Bandit.start_link(plug: HTTPErrorPlug, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      {:ok, [url: "http://localhost:#{port}/test"]}
    end

    test "exits when an HTTP error occurs", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      Process.flag(:trap_exit, true)
      uuid = Ecto.UUID.generate()
      {:ok, download} = UrlToFile.start_download(uuid, url, handler_fun, @short_retry_args)
      assert_receive {:error, {:http_error, 416}}
      assert_receive {:EXIT, ^download, {:http_error, 416}}
    end
  end

  describe "range" do
    setup do
      {:ok, pid} = Bandit.start_link(plug: RangeRequestPlug, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      {:ok, [url: "http://localhost:#{port}/test"]}
    end

    @tag :skip
    test "calculates range request header", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      uuid = Ecto.UUID.generate()
      {:ok, _} = UrlToFile.start_download(uuid, url, handler_fun, @short_retry_args)

      assert_receive {:download_progress, _}
      assert_receive {:complete, filepath}
      assert {:ok, "hello, world"} = File.read(filepath)
    end
  end

  describe "redirect" do
    setup do
      {:ok, pid} = Bandit.start_link(plug: {RedirectPlug, port: 123}, port: 123)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      {:ok, [url: "http://localhost:#{port}/redirect"]}
    end

    # @tag :skip
    test "follows redirects", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      uuid = Ecto.UUID.generate()
      {:ok, _download} = UrlToFile.start_download(uuid, url, handler_fun)
      refute_receive {:error, _}
      assert_receive {:download_progress, 100}
      assert_receive {:complete, _}
    end
  end

  describe "xretry" do
    setup do
      {:ok, pid} = Bandit.start_link(plug: XRetryNumberPlug, port: 123)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      {:ok, [url: "http://localhost:#{port}/test"]}
    end

    @tag :skip
    test "simple download resume", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      expected_data_part_1 = :binary.copy(<<0>>, 2048)
      expected_data_part_2 = :binary.copy(<<1>>, 2048)

      # download the first part of the data.
      # the plug will terminate the connection after 2048 bytes are sent.
      # the handler_fun will send the data to this test's mailbox.
      uuid = Ecto.UUID.generate()
      {:ok, _download} = UrlToFile.start_download(uuid, url, handler_fun, @short_retry_args)
      # download will be resumed after the error
      assert_receive {:error, _}
      assert_receive {:download_progress, 50}

      # the request should complete successfully this time
      assert_receive {:complete, filepath}
      assert expected_data_part_1 <> expected_data_part_2 == File.read!(filepath)
    end
  end
end
