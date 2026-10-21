require "../spec_helper"
require "../../src/matter/session/case/case"

# Captured with matter.js CaseMessages TlvCaseSigma1/TlvCaseSigma2Resume and
# StandardCrypto, from matter-js/packages/protocol at commit 7e1f5d7.
# The source checkout was built with `npm ci && npm run build`; its actual TLV
# encoders and AES-CCM/HKDF implementation produced these bytes independently.
describe "matter.js CASE resumption wire vectors" do
  it "decodes matter.js Sigma1 and verifies its Resume1 MIC" do
    secret = ("0123456789abcdef" * 4).hexbytes
    sigma1_bytes = "15300120202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f2502341230032000000000000000000000000000000000000000000000000000000000000000003004410401010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101300610404142434445464748494a4b4c4d4e4f30071093b939e737a9f1cd16890184e741340d18".hexbytes
    sigma1 = Matter::Session::Case::Definitions::Sigma1.from_slice(sigma1_bytes)

    sigma1.initiator_session_id.should eq(0x1234_u16)
    id = sigma1.resumption_id.as(Bytes)
    mic = sigma1.initiator_resume_mic.as(Bytes)
    Matter::Session::Case.valid_resume1_mic?(Matter::Crypto::StandardCrypto.new,
      secret, sigma1.initiator_random, id, mic).should be_true
    sigma1.to_slice.should eq(sigma1_bytes)
  end

  it "encodes matter.js Sigma2Resume and verifies its Resume2 MIC" do
    secret = ("0123456789abcdef" * 4).hexbytes
    random = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f".hexbytes
    sigma2_bytes = "15300110505152535455565758595a5b5c5d5e5f300210e78f4aea18d42193b45efa8c67d1bc2b2503785618".hexbytes
    sigma2 = Matter::Session::Case::Definitions::Sigma2Resume.from_slice(sigma2_bytes)

    sigma2.responder_session_id.should eq(0x5678_u16)
    Matter::Session::Case.valid_resume2_mic?(Matter::Crypto::StandardCrypto.new,
      secret, random, sigma2.resumption_id, sigma2.resume_mic).should be_true
    sigma2.to_slice.should eq(sigma2_bytes)
  end
end
