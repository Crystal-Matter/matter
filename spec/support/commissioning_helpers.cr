require "../../src/matter/commissioning"

# Records what a failsafe rollback asked it to restore, so a rollback can be
# asserted on without a cluster.
class RecordingRollbackTarget
  include Matter::Commissioning::RollbackTargets

  getter network_state : Matter::Storage::Document?
  getter regulatory_config : Tuple(UInt8, String)?
  getter windows_closed : Int32 = 0

  def restore_network_state(snapshot : Matter::Storage::Document) : Nil
    @network_state = snapshot
  end

  def commit_network_state : Nil
  end

  def restore_regulatory_config(location_type : UInt8, country_code : String) : Nil
    @regulatory_config = {location_type, country_code}
  end

  def close_commissioning_window : Nil
    @windows_closed += 1
  end
end

# Every restore step fails; a rollback must still complete.
class RaisingRollbackTarget
  include Matter::Commissioning::RollbackTargets

  def restore_network_state(snapshot : Matter::Storage::Document) : Nil
    raise Matter::CommissioningError.new("network restore failed")
  end

  def commit_network_state : Nil
  end

  def restore_regulatory_config(location_type : UInt8, country_code : String) : Nil
    raise Matter::CommissioningError.new("regulatory restore failed")
  end

  def close_commissioning_window : Nil
    raise Matter::CommissioningError.new("window close failed")
  end
end

# Captures what the window service published, standing in for the cluster
# attributes a commissioner reads.
class RecordingWindowTarget
  include Matter::Commissioning::WindowTarget

  getter status : Matter::Commissioning::WindowStatus = Matter::Commissioning::WindowStatus::WindowNotOpen
  getter admin_fabric_index : UInt8?
  getter admin_vendor_id : UInt16?
  getter notifications : Int32 = 0

  def publish_window_state(
    status : Matter::Commissioning::WindowStatus,
    admin_fabric_index : UInt8?,
    admin_vendor_id : UInt16?,
    notify : Bool,
  ) : Nil
    @status = status
    @admin_fabric_index = admin_fabric_index
    @admin_vendor_id = admin_vendor_id
    @notifications += 1 if notify
  end
end

# Records the credential changes the service publishes outside the fabric table.
class RecordingCredentialTarget
  include Matter::Commissioning::CredentialTarget

  getter trusted_root_certificates : Array(Bytes) = [] of Bytes
  getter changes : Int32 = 0
  getter committed : Array(Tuple(UInt8, UInt64)) = [] of Tuple(UInt8, UInt64)
  getter forgotten : Array(UInt8) = [] of UInt8

  def credentials_changed : Nil
    @changes += 1
  end

  def fabric_committed(fabric : Matter::Fabric, case_admin_subject : UInt64) : Nil
    @committed << {fabric.fabric_index, case_admin_subject}
  end

  def fabric_forgotten(fabric_index : UInt8) : Nil
    @forgotten << fabric_index
  end
end

# Matter TLV certificates the credential flow accepts.
# Certificates for commissioning specs, issued by the shared test authority.
module CommissioningCertificates
  extend self

  def public_key : Bytes
    TestCertificateAuthority.default.node_public_key
  end

  def root_public_key : Bytes
    TestCertificateAuthority.default.root_public_key
  end

  def root_certificate(rcac_id : UInt64 = TestCertificateAuthority::ROOT_CERTIFICATE_ID) : Bytes
    TestCertificateAuthority.default.root_certificate(rcac_id)
  end

  def noc(
    fabric_id : UInt64 = TestCertificateAuthority::DEFAULT_FABRIC_ID,
    node_id : UInt64 = TestCertificateAuthority::DEFAULT_NODE_ID,
  ) : Bytes
    TestCertificateAuthority.default.issue(fabric_id, node_id)
  end

  def foreign_noc(
    fabric_id : UInt64 = TestCertificateAuthority::DEFAULT_FABRIC_ID,
    node_id : UInt64 = TestCertificateAuthority::DEFAULT_NODE_ID,
  ) : Bytes
    TestCertificateAuthority.default.foreign_noc(fabric_id, node_id)
  end
end
