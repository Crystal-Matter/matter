require "../../src/matter/cluster/general_commissioning"
require "../../src/matter/cluster/network_commissioning"

# Wire-command fixtures must model the armed commissioning context required by
# Matter 1.6 Network Commissioning. The default context belongs to PASE.
def arm_network_commissioning(cluster : Matter::Cluster::NetworkCommissioning) : Matter::Cluster::GeneralCommissioning
  commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
  cluster.general_commissioning = commissioning
  commissioning.arm_fail_safe(60_u16)
  commissioning
end
