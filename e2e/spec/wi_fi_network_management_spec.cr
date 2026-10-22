require "./e2e_helper"

# An Aggregator test endpoint hosts only the opt-in Wi-Fi cluster; this fixture
# does not advertise the Network Infrastructure Manager device type.
describe "synthetic Wi-Fi Network Management interoperability" do
  device = E2E::Device["matter_wifi_management"]
  test_ssid = "Crystal Test Wi-Fi"
  test_passphrase = "correct horse"

  it "serves nullable metadata, a CASE passphrase, stable restart state, and Manage ACLs" do
    device.commission!

    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x0451_i64)
    read_int(device, "wifinetworkmanagement", "cluster-revision", "ClusterRevision", 1).should eq(1)

    empty_ssid = expect_success(device.read("wifinetworkmanagement", "ssid", 2))
    empty_ssid.output.should match(/\bSSID:\s*(?:<)?null(?:>)?/i)
    empty_surrogate = expect_success(device.read("wifinetworkmanagement", "passphrase-surrogate", 2))
    empty_surrogate.output.should match(/\bPassphraseSurrogate:\s*(?:<)?null(?:>)?/i)
    expect_failure(device.invoke("wifinetworkmanagement", "network-passphrase-request", endpoint: 2), "INVALID_IN_STATE")

    ssid = expect_success(device.read("wifinetworkmanagement", "ssid", 1))
    (ssid.output.includes?(test_ssid) || ssid.output.downcase.includes?(test_ssid.to_slice.hexstring)).should be_true
    read_int(device, "wifinetworkmanagement", "passphrase-surrogate", "PassphraseSurrogate", 1).should eq(42)
    passphrase = expect_success(device.invoke("wifinetworkmanagement", "network-passphrase-request", endpoint: 1))
    passphrase.output.should contain("Passphrase")
    (passphrase.output.includes?(test_passphrase) || passphrase.output.downcase.includes?(test_passphrase.to_slice.hexstring)).should be_true

    device.restart!
    read_int(device, "wifinetworkmanagement", "passphrase-surrogate", "PassphraseSurrogate", 1).should eq(42)
    expect_success(device.invoke("wifinetworkmanagement", "network-passphrase-request", endpoint: 1))

    # Restrict this fabric's CASE controller to View. SSID remains visible;
    # Manage-only metadata and the credential command must be denied.
    view_acl = %([{"fabricIndex":1,"privilege":1,"authMode":2,"subjects":[],"targets":[]}])
    expect_success(device.write("accesscontrol", "acl", view_acl, 0))
    expect_success(device.read("wifinetworkmanagement", "ssid", 1))
    expect_failure(device.read("wifinetworkmanagement", "passphrase-surrogate", 1), "UNSUPPORTED_ACCESS")
    expect_failure(device.invoke("wifinetworkmanagement", "network-passphrase-request", endpoint: 1), "UNSUPPORTED_ACCESS")
  end
end
