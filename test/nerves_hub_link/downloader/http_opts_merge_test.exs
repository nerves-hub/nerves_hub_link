# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Downloader.HttpOptsMergeTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Downloader

  describe "merge_http_opts/2" do
    test "preserves base transport_opts when user has no transport_opts" do
      proxy = {:http, "proxy.example", 8080, []}

      opts = Downloader.merge_http_opts([transport_opts: [verify: :verify_peer]], proxy: proxy)

      assert opts[:transport_opts] == [verify: :verify_peer]
      assert opts[:proxy] == proxy
    end

    test "transport_opts deep-merge with user keys layered on top" do
      opts =
        Downloader.merge_http_opts(
          [transport_opts: [verify: :verify_peer, cacerts: [:fake_ca]]],
          transport_opts: [timeout: 30_000]
        )

      assert opts[:transport_opts][:verify] == :verify_peer
      assert opts[:transport_opts][:cacerts] == [:fake_ca]
      assert opts[:transport_opts][:timeout] == 30_000
    end

    test "user transport_opts can override individual base keys" do
      opts =
        Downloader.merge_http_opts(
          [transport_opts: [verify: :verify_peer]],
          transport_opts: [verify: :verify_none]
        )

      assert opts[:transport_opts][:verify] == :verify_none
    end
  end
end
