# SPDX-FileCopyrightText: 2020 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#

Mox.defmock(NervesHubLink.ClientMock, for: NervesHubLink.Client)
Mox.defmock(NervesHubLink.UpdateManager.UpdaterMock, for: NervesHubLink.UpdateManager.Updater)

Application.put_env(:nerves_hub_link, :client, NervesHubLink.ClientMock)

ExUnit.start(capture_log: true)
