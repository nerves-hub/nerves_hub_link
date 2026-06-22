# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketTest do
  use ExUnit.Case, async: true

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
      assert opts[:transport_opts] == [verify: :verify_peer]
    end

    test "ws omits transport_opts" do
      config = %Config{
        socket: [url: URI.parse("ws://example.test/socket")],
        ssl: [verify: :verify_peer]
      }

      opts = Socket.mint_opts(config)

      assert opts[:protocols] == [:http1]
      refute Keyword.has_key?(opts, :transport_opts)
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
      assert opts[:transport_opts] == [verify: :verify_peer]
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
  end
end
