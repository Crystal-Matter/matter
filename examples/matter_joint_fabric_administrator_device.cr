require "./support/main"
require "./support/joint_fabric_administrator_device"

Examples.main("Matter Joint Fabric Administrator") do
  MatterJointFabricAdministrator::Device.new(port: ENV["MATTER_JFA_PORT"]?.try(&.to_i?) || 5540)
end
