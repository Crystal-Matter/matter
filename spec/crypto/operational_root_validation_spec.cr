require "../spec_helper"
require "../../src/matter/cluster/operational_credentials"

private def signed_root_change(root : Bytes, key : Matter::Crypto::Key,
                               & : TLV::Structure -> Nil) : Bytes
  fields = TLV::Any.from_slice(root).as_structure
  yield fields
  unsigned = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
  signature = Matter::Crypto::StandardCrypto.new.sign_ecdsa(key, unsigned)
  fields[Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value] =
    TLV::Any.new(signature, Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value)
  TLV::Any.new(fields, nil).to_slice
end

private def root_install_outcome(root : Bytes) : Matter::Commissioning::NocOutcome
  cluster = Matter::Cluster::OperationalCredentials.new(Matter::FabricTable.new(Matter::Storage::Memory.new))
  cluster.credentials.failsafe_armed = true
  outcome = cluster.credentials.add_trusted_root_certificate(root)
  if outcome.ok?
    cluster.trusted_root_certificates.should eq([root])
  else
    cluster.trusted_root_certificates.should be_empty
  end
  outcome
end

describe Matter::Crypto::MatterCertificate::Validation do
  it "installs a self-signed RCAC with an unbounded Matter NotAfter" do
    authority = TestCertificateAuthority.new
    root = signed_root_change(authority.root_certificate, authority.key) do |fields|
      fields[Matter::Crypto::MatterCertificate::Asn1::Field::NotAfter.value] =
        TLV::Any.new(0_u32, Matter::Crypto::MatterCertificate::Asn1::Field::NotAfter.value)
    end
    root_install_outcome(root).ok?.should be_true
  end

  it "rejects an RCAC whose issuer differs from its subject" do
    authority = TestCertificateAuthority.new
    root = signed_root_change(authority.root_certificate, authority.key) do |fields|
      fields[Matter::Crypto::MatterCertificate::Asn1::Field::Issuer.value] = TLV::Any.new(
        TLV::List{TLV::Any.new(99_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::RcacId.value)},
        Matter::Crypto::MatterCertificate::Asn1::Field::Issuer.value)
    end
    root_install_outcome(root).status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
  end

  it "rejects a signed root certificate without CA authority" do
    authority = TestCertificateAuthority.new
    root = signed_root_change(authority.root_certificate, authority.key) do |fields|
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      tag = Matter::Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value
      index = extensions.index { |extension| extension.header.ids == tag }.as(Int32)
      constraints = extensions[index].as_structure
      constraints[Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA] =
        TLV::Any.new(false, Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA)
    end
    root_install_outcome(root).status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
  end

  it "rejects an RCAC whose authority key identifier differs from its subject key identifier" do
    authority = TestCertificateAuthority.new
    root = signed_root_change(authority.root_certificate, authority.key) do |fields|
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      tag = Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value
      index = extensions.index { |extension| extension.header.ids == tag }.as(Int32)
      extensions[index] = TLV::Any.new(Bytes.new(20, 0_u8), tag)
    end
    root_install_outcome(root).status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
  end

  it "rejects an RCAC signature substituted from another root" do
    authority = TestCertificateAuthority.new
    impostor = TestCertificateAuthority.new
    fields = TLV::Any.from_slice(authority.root_certificate).as_structure
    impostor_fields = TLV::Any.from_slice(impostor.root_certificate).as_structure
    fields[Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value] =
      impostor_fields[Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value]
    root_install_outcome(TLV::Any.new(fields, nil).to_slice).status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
  end

  it "accepts an expired but otherwise valid RCAC as a trust anchor" do
    authority = TestCertificateAuthority.new
    root = authority.root_certificate
    Timecop.travel(Time.utc + 11.years) do
      root_install_outcome(root).ok?.should be_true
    end
  end
end
