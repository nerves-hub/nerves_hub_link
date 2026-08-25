# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.DownloaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias NervesHubLink.Support.{
    DoneNotDonePlug,
    HTTPErrorPlug,
    IdleTimeoutPlug,
    RangeRequestPlug,
    RedirectPlug,
    ResumedRangePlug,
    Utils,
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

  @failure_url "http://localhost:#{Utils.unique_port_number()}/this_should_fail"

  # the size of the file `ResumedRangePlug` is asked to serve
  @served_bytes 4096

  test "max_disconnects" do
    test_pid = self()
    handler_fun = &send(test_pid, &1)

    retry_args = RetryConfig.validate(max_disconnects: 2, time_between_retries: 1)

    Process.flag(:trap_exit, true)

    {:ok, download} =
      Downloader.start_download(@failure_url, handler_fun, retry_config: retry_args)

    # should receive this one twice
    assert_receive {:error, %Mint.TransportError{reason: :econnrefused}}, 1000
    assert_receive {:error, %Mint.TransportError{reason: :econnrefused}}
    # then exit
    assert_receive {:EXIT, ^download, :max_disconnects_reached}
  end

  test "max_timeout" do
    test_pid = self()
    handler_fun = &send(test_pid, &1)

    retry_args = RetryConfig.validate(max_timeout: 10)

    Process.flag(:trap_exit, true)

    {:ok, download} =
      Downloader.start_download(@failure_url, handler_fun, retry_config: retry_args)

    assert_receive {:error, %Mint.TransportError{reason: :econnrefused}}, 1000
    assert_receive {:EXIT, ^download, :max_timeout_reached}, 1000
  end

  describe "idle timeout" do
    setup do
      {:ok, plug, port} = Utils.supervise_plug(IdleTimeoutPlug)
      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "idle_timeout causes retry", %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      retry_args =
        RetryConfig.validate(
          idle_timeout: 100,
          time_between_retries: 10
        )

      {:ok, _download} = Downloader.start_download(url, handler_fun, retry_config: retry_args)
      assert_receive {:error, :idle_timeout}, 1000
      assert_receive {:data, "content", _}
      assert_receive :complete
    end
  end

  describe "http error" do
    setup do
      {:ok, plug, port} = Utils.supervise_plug(HTTPErrorPlug)
      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "exits when an HTTP error occurs", %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      Process.flag(:trap_exit, true)

      {:ok, download} =
        Downloader.start_download(url, handler_fun, retry_config: @short_retry_args)

      assert_receive {:error, %Mint.HTTPError{reason: {:http_error, 416}}}, 1000
      assert_receive {:EXIT, ^download, {:http_error, 416}}
    end
  end

  describe "range" do
    setup do
      {:ok, plug, port} = Utils.supervise_plug(RangeRequestPlug)
      {:ok, [plug: plug, url: "http://localhost:#{port}/range"]}
    end

    test "calculates range request header", %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      {:ok, download} =
        Downloader.start_download(url, handler_fun, retry_config: @short_retry_args)

      assert_receive {:data, "h", _}, 1000
      assert_receive {:error, _}

      refute_receive {:error, _}
      # cspell:disable-next-line
      assert_receive {:data, "ello, world", _}

      assert_receive :complete

      refute Process.alive?(download)
    end
  end

  describe "redirect" do
    setup do
      {:ok, plug, port} = Utils.supervise_plug(RedirectPlug)
      {:ok, [plug: plug, url: "http://localhost:#{port}/redirect"]}
    end

    test "follows redirects", %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      {:ok, download} = Downloader.start_download(url, handler_fun)

      refute_receive {:error, _}
      assert_receive {:data, "redirected", _}

      assert_receive :complete

      refute Process.alive?(download)
    end
  end

  describe "done but not done" do
    setup do
      {:ok, plug, port} = Utils.supervise_plug(DoneNotDonePlug)
      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "retries when Mint signals done before all bytes are received", %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      expected_data_part_1 = :binary.copy(<<0>>, 2048)
      expected_data_part_2 = :binary.copy(<<1>>, 1024)
      expected_data_part_3 = :binary.copy(<<1>>, 1024)

      {:ok, _download} =
        Downloader.start_download(url, handler_fun, retry_config: @short_retry_args)

      # First request: receives partial data then connection error
      assert_receive {:data, ^expected_data_part_1, _}, 1000
      assert_receive {:error, _}

      # Second request: Mint signals :done (chunked terminator) but
      # downloaded_length (3072) != content_length (4096)
      assert_receive {:data, ^expected_data_part_2, _}
      assert_receive {:error, _reason}

      # Third request: receives remaining data and completes
      assert_receive {:data, ^expected_data_part_3, _}
      assert_receive :complete
    end
  end

  describe "x retry" do
    setup do
      {:ok, plug, port} = Utils.supervise_plug(XRetryNumberPlug)
      {:ok, [plug: plug, url: "http://localhost:#{port}/test"]}
    end

    test "simple download resume", %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      expected_data_part_1 = :binary.copy(<<0>>, 2048)
      expected_data_part_2 = :binary.copy(<<1>>, 2048)

      # download the first part of the data.
      # the plug will terminate the connection after 2048 bytes are sent.
      # the handler_fun will send the data to this test's mailbox.
      {:ok, _download} =
        Downloader.start_download(url, handler_fun, retry_config: @short_retry_args)

      assert_receive {:data, ^expected_data_part_1, _}, 1000

      # download will be resumed after the error
      assert_receive {:error, _}

      # second part should now be delivered
      assert_receive {:data, ^expected_data_part_2, _}

      # the request should complete successfully this time
      assert_receive :complete
    end
  end

  describe "logging" do
    test "labels its lines so downloads running side by side can be told apart" do
      handler_fun = fn _message -> :ok end
      retry_config = RetryConfig.validate(max_disconnects: 1, time_between_retries: 1)

      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, download} =
            Downloader.start_download(@failure_url, handler_fun,
              retry_config: retry_config,
              label: "parts 3 to 4"
            )

          assert_receive {:EXIT, ^download, :max_disconnects_reached}, 1000
        end)

      assert log =~ "[NervesHubLink.Downloader parts 3 to 4]"
    end

    test "leaves the lines of an unlabelled download alone" do
      handler_fun = fn _message -> :ok end
      retry_config = RetryConfig.validate(max_disconnects: 1, time_between_retries: 1)

      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, download} =
            Downloader.start_download(@failure_url, handler_fun, retry_config: retry_config)

          assert_receive {:EXIT, ^download, :max_disconnects_reached}, 1000
        end)

      assert log =~ "[NervesHubLink.Downloader]"
    end

    test "keeps the signed part of a firmware URL out of the log" do
      handler_fun = fn _message -> :ok end
      retry_config = RetryConfig.validate(max_disconnects: 2, time_between_retries: 1)

      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, download} =
            Downloader.start_download(
              @failure_url <> "?X-Amz-Signature=do-not-log-me",
              handler_fun,
              retry_config: retry_config
            )

          assert_receive {:EXIT, ^download, :max_disconnects_reached}, 1000
        end)

      # both in the lines the downloader writes itself, and in the crash report
      # OTP writes for it, which reports the whole state
      assert downloader_lines(log) =~ "Resuming download attempt number 1"
      assert log =~ "max_disconnects_reached"
      refute log =~ "do-not-log-me"
    end

    # The test above covers the wiring - the signature reaches the log through
    # OTP's crash report unless `format_status/1` is called. This one covers
    # what is taken out, which is more than a crash is convenient to produce.
    test "takes secrets out of the state reported on a crash, and nothing else" do
      state = %Downloader{
        uri: URI.parse("https://example.test/firmware.fw?X-Amz-Signature=do-not-log-me"),
        transport_opts: [
          key: "PRIVATE-KEY-MATERIAL",
          server_name_indication: ~c"nerves-hub.org"
        ],
        http_opts: [
          proxy_headers: [{"proxy-authorization", "Basic do-not-log-me"}],
          transport_opts: [password: "do-not-log-me"]
        ],
        retry_number: 2
      }

      assert %{state: redacted} = Downloader.format_status(%{state: state})

      assert redacted.uri.query == "[REDACTED]"
      assert redacted.transport_opts[:key] == "[REDACTED]"
      assert redacted.http_opts[:proxy_headers] == "[REDACTED]"

      # nested, because SSL options are merged underneath the HTTP options
      assert redacted.http_opts[:transport_opts][:password] == "[REDACTED]"

      # the rest is what makes a crash report worth reading
      assert redacted.uri.host == "example.test"
      assert redacted.uri.path == "/firmware.fw"
      assert redacted.transport_opts[:server_name_indication] == ~c"nerves-hub.org"
      assert redacted.retry_number == 2

      refute inspect(redacted) =~ "do-not-log-me"
      refute inspect(redacted) =~ "PRIVATE-KEY-MATERIAL"
    end

    test "leaves a status without state alone" do
      assert Downloader.format_status(%{reason: :boom}) == %{reason: :boom}
    end
  end

  defp downloader_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "[NervesHubLink.Downloader"))
    |> Enum.join("\n")
  end

  describe "resuming a download that already skipped part of the file" do
    setup do
      {:ok, _plug, port} =
        Utils.supervise_plug(ResumedRangePlug,
          test_pid: self(),
          content_length: @served_bytes
        )

      {:ok, [url: "http://localhost:#{port}/test"]}
    end

    test "asks for offsets into the file rather than into the interrupted request",
         %{url: url} do
      test_pid = self()

      handler_fun = fn msg ->
        send(test_pid, msg)
        :ok
      end

      resume_from = div(@served_bytes, 4)
      remaining = @served_bytes - resume_from

      {:ok, _download} =
        Downloader.start_download(url, handler_fun,
          retry_config: @short_retry_args,
          resume_from_bytes: resume_from
        )

      # the first request picks up where the file on disk left off, and is cut
      # short half way through the bytes it was promised
      assert_receive {:range, 0, ^resume_from}, 1000
      first_half = :binary.copy(<<0>>, div(remaining, 2))
      assert_receive {:data, ^first_half, _}
      assert_receive {:error, _reason}

      # the retry has to account for the bytes that were skipped as well as the
      # ones that arrived, otherwise it stitches the wrong bytes together
      expected_offset = resume_from + div(remaining, 2)
      assert_receive {:range, 1, ^expected_offset}

      second_half = :binary.copy(<<1>>, div(remaining, 2))
      assert_receive {:data, ^second_half, _}
      assert_receive :complete
    end
  end
end
