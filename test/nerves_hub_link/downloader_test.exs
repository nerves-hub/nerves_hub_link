defmodule NervesHubLink.DownloaderTest do
  use ExUnit.Case

  alias NervesHubLink.Support.{
    HTTPErrorPlug,
    IdleTimeoutPlug,
    RangeRequestPlug,
    RedirectPlug,
    XRetryNumberPlug
  }

  alias NervesHubLink.{Downloader, Downloader.RetryConfig}

  @short_retry_args %RetryConfig{
    max_disconnects: 10,
    idle_timeout: 60_000,
    max_timeout: 3_600_000,
    time_between_retries: 10,
    worst_case_download_speed: 30_000
  }

  @failure_url "http://localhost/this_should_fail"

  test "max_disconnects" do
    test_pid = self()
    handler_fun = &send(test_pid, &1)

    retry_args = %RetryConfig{
      max_disconnects: 2,
      time_between_retries: 1
    }

    Process.flag(:trap_exit, true)
    {:ok, download} = Downloader.start_download(@failure_url, handler_fun, retry_args)
    # should receive this one twice
    assert_receive {:error, %Mint.TransportError{reason: :econnrefused}}, 1000
    assert_receive {:error, %Mint.TransportError{reason: :econnrefused}}
    # then exit
    assert_receive {:EXIT, ^download, :max_disconnects_reached}
  end

  test "max_timeout" do
    test_pid = self()
    handler_fun = &send(test_pid, &1)

    retry_args = %RetryConfig{
      max_timeout: 10
    }

    Process.flag(:trap_exit, true)
    {:ok, download} = Downloader.start_download(@failure_url, handler_fun, retry_args)
    assert_receive {:error, %Mint.TransportError{reason: :econnrefused}}, 1000
    assert_receive {:EXIT, ^download, :max_timeout_reached}
  end

  describe "idle timeout" do
    setup do
      port = 6000

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy, scheme: :http, plug: IdleTimeoutPlug, options: [port: port]}
        )

      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "idle_timeout causes retry", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)

      retry_args = %RetryConfig{
        idle_timeout: 100,
        time_between_retries: 10
      }

      {:ok, _download} = Downloader.start_download(url, handler_fun, retry_args)
      assert_receive {:error, :idle_timeout}, 1000
      assert_receive {:data, "content"}
      assert_receive :complete
    end
  end

  describe "http error" do
    setup do
      port = 6000

      {:ok, plug} =
        start_supervised({Plug.Cowboy, scheme: :http, plug: HTTPErrorPlug, options: [port: port]})

      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "exits when an HTTP error occurs", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      Process.flag(:trap_exit, true)
      {:ok, download} = Downloader.start_download(url, handler_fun, @short_retry_args)
      assert_receive {:error, %Mint.HTTPError{reason: {:http_error, 416}}}, 1000
      assert_receive {:EXIT, ^download, {:http_error, 416}}
    end
  end

  describe "range" do
    setup do
      port = 6000

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy, scheme: :http, plug: RangeRequestPlug, options: [port: port]}
        )

      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "calculates range request header", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      {:ok, _} = Downloader.start_download(url, handler_fun, @short_retry_args)

      assert_receive {:data, "h"}, 1000
      assert_receive {:error, _}

      refute_receive {:error, _}
      assert_receive {:data, "ello, world"}
    end
  end

  describe "redirect" do
    setup do
      port = 6000

      {:ok, plug} =
        start_supervised({Plug.Cowboy, scheme: :http, plug: RedirectPlug, options: [port: port]})

      {:ok, [plug: plug, url: "http://localhost:#{port}/redirect"]}
    end

    test "follows redirects", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      {:ok, _download} = Downloader.start_download(url, handler_fun)
      refute_receive {:error, _}
      assert_receive {:data, "redirected"}
    end
  end

  describe "xretry" do
    setup do
      port = 6000

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy, scheme: :http, plug: XRetryNumberPlug, options: [port: port]}
        )

      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "simple download resume", %{url: url} do
      test_pid = self()
      handler_fun = &send(test_pid, &1)
      expected_data_part_1 = :binary.copy(<<0>>, 2048)
      expected_data_part_2 = :binary.copy(<<1>>, 2048)

      # download the first part of the data.
      # the plug will terminate the connection after 2048 bytes are sent.
      # the handler_fun will send the data to this test's mailbox.
      {:ok, _download} = Downloader.start_download(url, handler_fun, @short_retry_args)
      assert_receive {:data, ^expected_data_part_1}, 1000

      # download will be resumed after the error
      assert_receive {:error, _}

      # second part should now be delivered
      assert_receive {:data, ^expected_data_part_2}

      # the request should complete successfully this time
      assert_receive :complete
    end
  end
end
