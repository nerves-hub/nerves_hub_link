# SPDX-FileCopyrightText: 2020 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#

Mox.defmock(NervesHubLink.ClientMock, for: NervesHubLink.Client)
Mox.defmock(NervesHubLink.UpdateManager.UpdaterMock, for: NervesHubLink.UpdateManager.Updater)

Application.put_env(:nerves_hub_link, :client, NervesHubLink.ClientMock)

# `assert_receive` waits 100ms by default. The downloader tests drive a real
# HTTP server through a dropped connection and a retry, and 100ms is not long
# enough for the message after the one that arrives first: they pass on a quiet
# machine and flake on a loaded CI runner. The first assertion of each of those
# tests already carries an explicit 1000ms for the same reason.
#
# This only changes how long a *failing* assertion waits. An assertion that is
# going to pass returns as soon as its message lands, so the suite is no slower
# for it.
ExUnit.start(capture_log: true, assert_receive_timeout: 2_000)
