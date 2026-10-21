require "./support/main"
require "./support/joint_fabric_administrator_device"

Examples.main("Matter Joint Fabric Administrator") do
  ip_addresses = ENV["MATTER_JFA_IP_ADDRESS"]?.try do |address|
    [Socket::IPAddress.new(address, Matter::Network::UNSPECIFIED_PORT)]
  end
  MatterJointFabricAdministrator::Device.new(
    ip_addresses: ip_addresses,
    port: ENV["MATTER_JFA_PORT"]?.try(&.to_i?) || 5540)
end
