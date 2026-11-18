# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketTest do
  use ExUnit.Case, async: true

  alias Mint.WebSocket.UpgradeFailureError
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Socket

  describe "mint_opts/1" do
    test "wss includes protocols and transport_opts from ssl" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:protocols] == [:http1]
      assert opts[:transport_opts][:verify] == :verify_peer
    end

    test "ws omits the ssl options" do
      config = %Config{
        socket: [url: URI.parse("ws://example.test/socket")],
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:protocols] == [:http1]
      refute Keyword.has_key?(opts[:transport_opts], :verify)
    end

    test "http_opts pass through to Mint.HTTP.connect options" do
      proxy = {:http, "proxy.example", 8080, []}

      config = %Config{
        socket: [
          url: URI.parse("wss://example.test/socket"),
          http_opts: [proxy: proxy]
        ],
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:proxy] == proxy
      assert opts[:protocols] == [:http1]
      assert opts[:transport_opts][:verify] == :verify_peer
    end

    test "http_opts can override base keys" do
      config = %Config{
        socket: [
          url: URI.parse("wss://example.test/socket"),
          http_opts: [protocols: [:http2]]
        ],
        ssl: []
      }

      opts = Socket.mint_opts(config)

      assert opts[:protocols] == [:http2]
    end

    test "http_opts transport_opts merge with ssl rather than clobbering it" do
      config = %Config{
        socket: [
          url: URI.parse("wss://example.test/socket"),
          http_opts: [transport_opts: [timeout: 30_000]]
        ],
        ssl: [verify: :verify_peer, cacerts: [:fake_ca]]
      }

      opts = Socket.mint_opts(config)

      assert opts[:transport_opts][:verify] == :verify_peer
      assert opts[:transport_opts][:cacerts] == [:fake_ca]
      assert opts[:transport_opts][:timeout] == 30_000
    end

    test "http_opts transport_opts can override individual ssl keys" do
      config = %Config{
        socket: [
          url: URI.parse("wss://example.test/socket"),
          http_opts: [transport_opts: [verify: :verify_none]]
        ],
        ssl: [verify: :verify_peer, cacerts: [:fake_ca]]
      }

      opts = Socket.mint_opts(config)

      assert opts[:transport_opts][:verify] == :verify_none
      assert opts[:transport_opts][:cacerts] == [:fake_ca]
    end

    # Without a send timeout a stalled write blocks the connection forever, and
    # blocks the heartbeat that would otherwise notice the link is dead.
    test "writes are bounded by a send timeout over wss" do
      config = %Config{socket: [url: URI.parse("wss://example.test/socket")], ssl: []}

      opts = Socket.mint_opts(config)

      assert opts[:transport_opts][:send_timeout] == 30_000
      assert opts[:transport_opts][:send_timeout_close] == true
    end

    test "writes are bounded by a send timeout over ws too" do
      config = %Config{socket: [url: URI.parse("ws://example.test/socket")], ssl: []}

      opts = Socket.mint_opts(config)

      assert opts[:transport_opts][:send_timeout] == 30_000
      assert opts[:transport_opts][:send_timeout_close] == true
    end

    test "the connect timeout is set" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        ssl: []
      }

      assert Socket.mint_opts(config)[:transport_opts][:timeout] == 10_000
    end

    test "the connect timeout is configurable" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        connect_timeout_msec: 5_000,
        ssl: []
      }

      assert Socket.mint_opts(config)[:transport_opts][:timeout] == 5_000
    end

    test "a connect timeout of zero leaves the timeout to Mint" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        connect_timeout_msec: 0,
        ssl: []
      }

      refute Keyword.has_key?(Socket.mint_opts(config)[:transport_opts], :timeout)
    end

    test "ssl options win over the default connect timeout" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        ssl: [timeout: 1_000]
      }

      assert Socket.mint_opts(config)[:transport_opts][:timeout] == 1_000
    end

    test "the send timeout is configurable" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        send_timeout_msec: 5_000,
        ssl: []
      }

      assert Socket.mint_opts(config)[:transport_opts][:send_timeout] == 5_000
    end

    test "ssl options win over the default send timeout" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        ssl: [send_timeout: 1_000]
      }

      assert Socket.mint_opts(config)[:transport_opts][:send_timeout] == 1_000
    end

    test "http_opts transport_opts win over the default send timeout" do
      config = %Config{
        socket: [
          url: URI.parse("wss://example.test/socket"),
          http_opts: [transport_opts: [send_timeout: 2_000]]
        ],
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:transport_opts][:send_timeout] == 2_000
      assert opts[:transport_opts][:verify] == :verify_peer
    end

    test "a send timeout of 0 leaves writes unbounded" do
      config = %Config{
        socket: [url: URI.parse("wss://example.test/socket")],
        send_timeout_msec: 0,
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      refute Keyword.has_key?(opts[:transport_opts], :send_timeout)
      assert opts[:transport_opts][:verify] == :verify_peer
    end

    test "a send timeout of 0 over ws leaves the connect timeout" do
      config = %Config{
        socket: [url: URI.parse("ws://example.test/socket")],
        send_timeout_msec: 0,
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:protocols] == [:http1]
      assert opts[:transport_opts] == [timeout: 10_000]
    end

    test "both timeouts off over ws omits transport_opts entirely" do
      config = %Config{
        socket: [url: URI.parse("ws://example.test/socket")],
        connect_timeout_msec: 0,
        send_timeout_msec: 0,
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:protocols] == [:http1]
      refute Keyword.has_key?(opts, :transport_opts)
    end
  end

  describe "serializer_for/1" do
    test "JSON asks for the v2 protocol" do
      assert {uri, serializer} = Socket.serializer_for(config(serializer: :json))

      assert serializer == NervesHubLink.Connection.Serializer.JSON
      assert uri.query == "vsn=2.0.0"
    end

    test "msgpack asks for the v3 protocol" do
      assert {uri, serializer} = Socket.serializer_for(config(serializer: :msgpack))

      assert serializer == NervesHubLink.Connection.Serializer.MsgPack
      assert uri.query == "vsn=3.0.0"
    end

    test "an unknown serializer falls back to JSON rather than refusing to connect" do
      assert {uri, serializer} = Socket.serializer_for(config(serializer: :something_else))

      assert serializer == NervesHubLink.Connection.Serializer.JSON
      assert uri.query == "vsn=2.0.0"
    end

    test "other query parameters on a configured URL are kept" do
      config = config(serializer: :json, url: "wss://example.test/socket?region=eu")

      assert {uri, _serializer} = Socket.serializer_for(config)

      query = URI.decode_query(uri.query)
      assert query["region"] == "eu"
      assert query["vsn"] == "2.0.0"
    end

    test "a vsn in a configured URL does not override the one the serializer needs" do
      config = config(serializer: :msgpack, url: "wss://example.test/socket?vsn=2.0.0")

      assert {uri, _serializer} = Socket.serializer_for(config)

      assert URI.decode_query(uri.query)["vsn"] == "3.0.0"
    end
  end

  describe "upgrade_failure/1" do
    test "reports the status and headers of a failed upgrade" do
      headers = [{"location", "https://other.test/socket/websocket"}]

      assert {:ok, 302, ^headers} = Socket.upgrade_failure(upgrade_failure(302, headers))
    end

    test "any other disconnect reason is not an upgrade failure" do
      assert Socket.upgrade_failure(:closed) == :error
      assert Socket.upgrade_failure(:heartbeat_timeout) == :error
      assert Socket.upgrade_failure({:error, :nxdomain}) == :error
      assert Socket.upgrade_failure({:upgrade_failure, :something}) == :error

      # A nested `{:error, {:upgrade_failure, %{reason: _}}}` is not what
      # `NervesHubLink.Connection` reports, so it is not taken for one.
      assert Socket.upgrade_failure(
               {:error, {:upgrade_failure, %{reason: %UpgradeFailureError{}}}}
             ) == :error
    end
  end

  describe "redirect_uri/2" do
    test "an absolute location replaces the URL, as a websocket scheme" do
      headers = [{"location", "https://other.test/socket/websocket"}]

      assert {:ok, uri} = Socket.redirect_uri(URI.parse("wss://old.test/socket"), headers)
      assert URI.to_string(uri) == "wss://other.test/socket/websocket"
    end

    test "a relative location is merged onto the URL the device just tried" do
      headers = [{"location", "/elsewhere/websocket"}]

      assert {:ok, uri} = Socket.redirect_uri(URI.parse("wss://old.test/socket"), headers)
      assert URI.to_string(uri) == "wss://old.test/elsewhere/websocket"
    end

    test "an http location becomes ws" do
      headers = [{"location", "http://other.test/socket"}]

      assert {:ok, uri} = Socket.redirect_uri(URI.parse("ws://old.test/socket"), headers)
      assert uri.scheme == "ws"
    end

    test "a location that already names a websocket scheme is left alone" do
      headers = [{"location", "wss://other.test/socket"}]

      assert {:ok, uri} = Socket.redirect_uri(URI.parse("wss://old.test/socket"), headers)
      assert uri.scheme == "wss"
    end

    test "other headers are ignored" do
      headers = [{"date", "Sun, 06 Nov 1994 08:49:37 GMT"}, {"location", "https://other.test/"}]

      assert {:ok, uri} = Socket.redirect_uri(URI.parse("wss://old.test/socket"), headers)
      assert uri.host == "other.test"
    end

    # The `vsn` names the protocol the serializer was chosen for, and
    # `URI.merge/2` takes its query from the `Location` whenever that carries a
    # path. A redirect naming no query of its own would drop it, leaving
    # Phoenix to read these frames with its default serializer.
    test "a redirect that carries no query keeps the current one" do
      current = URI.parse("wss://old.test/socket/websocket?vsn=2.0.0")

      assert {:ok, relative} = Socket.redirect_uri(current, [{"location", "/socket/websocket"}])
      assert relative.query == "vsn=2.0.0"

      assert {:ok, absolute} =
               Socket.redirect_uri(current, [{"location", "https://new.test/socket/websocket"}])

      assert absolute.host == "new.test"
      assert absolute.query == "vsn=2.0.0"
    end

    test "a redirect that carries its own query keeps that one" do
      current = URI.parse("wss://old.test/socket/websocket?vsn=2.0.0")

      assert {:ok, uri} =
               Socket.redirect_uri(current, [{"location", "/socket/websocket?vsn=3.0.0"}])

      assert uri.query == "vsn=3.0.0"
    end

    # A 3xx with nowhere to redirect to must not crash the socket process.
    test "a redirect without a location is an error rather than a crash" do
      assert Socket.redirect_uri(URI.parse("wss://old.test/socket"), []) == :error

      assert Socket.redirect_uri(URI.parse("wss://old.test/socket"), [{"location", ""}]) ==
               :error
    end
  end

  defp config(opts) do
    {url, opts} = Keyword.pop(opts, :url, "wss://example.test/socket/websocket")

    struct(
      %Config{socket: [url: URI.parse(url)], ssl: []},
      opts
    )
  end

  # The shape `NervesHubLink.Connection` emits.
  defp upgrade_failure(status, headers) do
    {:upgrade_failure, %UpgradeFailureError{status_code: status, headers: headers}}
  end
end
