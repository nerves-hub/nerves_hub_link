# SPDX-FileCopyrightText: 2019 Daniel Spofford
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2021 Connor Rigby
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.CertificateTest do
  use ExUnit.Case, async: false
  alias NervesHubLink.Certificate

  doctest Certificate

  describe "pem_to_der/1" do
    test "some values return empty string" do
      assert Certificate.pem_to_der("") == ""
      assert Certificate.pem_to_der(nil) == ""
    end
  end

  test "ca_certs/0" do
    certs = Certificate.ca_certs()
    assert certs == ["Everyone", "gets", "a", "CA"]
    for cert <- certs, do: assert(is_binary(cert))
  end
end
