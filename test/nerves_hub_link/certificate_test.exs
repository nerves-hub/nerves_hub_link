defmodule NervesHubLink.CertificateTest do
  use ExUnit.Case, async: true
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

  test "fwup_public_keys/0" do
    assert is_list(Certificate.fwup_public_keys())
  end
end
