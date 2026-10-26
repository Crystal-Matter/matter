require "../../src/matter/cluster/cluster"

# Test double for Interaction Model event filtering. Matter's standard ARL
# checker allows cluster ID 0x0453 on a non-root endpoint, but the actual
# Thread Network Directory cluster declares no events. These synthetic events
# exercise generic IM plumbing and make no conformance claim for that cluster.
class AllowedArlEventCluster < Matter::Cluster::Base
  cluster 0x0453, revision: 1, persist_state: false

  attribute 0x0000, :value, UInt8, default: 0_u8
  event 0x00, :restricted, priority: :critical
  event 0x01, :allowed, priority: :critical
end
