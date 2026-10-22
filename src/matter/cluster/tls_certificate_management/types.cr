require "tlv"
require "../../storage/record"

module Matter
  module Cluster
    class TlsCertificateManagement < Base
      # Wire structs from Matter 1.6 TLS Certificate Management revision 1.
      module Tlv
        struct Cert
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter caid : UInt16
          @[::TLV::Field(tag: 1, optional: true)]
          getter certificate : Bytes?
          @[::TLV::Field(tag: 254)]
          getter fabric_index : UInt8

          def initialize(@caid : UInt16, @certificate : Bytes?, @fabric_index : UInt8); end
        end

        struct ClientCertificateDetail
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter ccdid : UInt16
          @[::TLV::Field(tag: 1, optional: false)]
          getter client_certificate : Bytes?
          @[::TLV::Field(tag: 2, optional: true)]
          getter intermediate_certificates : Array(Bytes)?
          @[::TLV::Field(tag: 254)]
          getter fabric_index : UInt8

          def initialize(@ccdid : UInt16, @client_certificate : Bytes?, @intermediate_certificates : Array(Bytes)?, @fabric_index : UInt8); end
        end

        struct ProvisionRootCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter certificate : Bytes
          @[::TLV::Field(tag: 1, optional: false)]
          getter caid : UInt16?

          def initialize(@certificate : Bytes, @caid : UInt16?); end
        end

        struct ProvisionRootCertificateResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter caid : UInt16

          def initialize(@caid : UInt16); end
        end

        struct FindRootCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0, optional: false)]
          getter caid : UInt16?

          def initialize(@caid : UInt16?); end
        end

        struct FindRootCertificateResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter certificate_details : Array(Cert)

          def initialize(@certificate_details : Array(Cert)); end
        end

        struct LookupRootCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter fingerprint : Bytes

          def initialize(@fingerprint : Bytes); end
        end

        struct LookupRootCertificateResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter caid : UInt16

          def initialize(@caid : UInt16); end
        end

        struct RemoveRootCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter caid : UInt16

          def initialize(@caid : UInt16); end
        end

        struct ClientCsrRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter nonce : Bytes
          @[::TLV::Field(tag: 1, optional: false)]
          getter ccdid : UInt16?

          def initialize(@nonce : Bytes, @ccdid : UInt16?); end
        end

        struct ClientCsrResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter ccdid : UInt16
          @[::TLV::Field(tag: 1)]
          getter csr : Bytes
          @[::TLV::Field(tag: 2)]
          getter nonce_signature : Bytes

          def initialize(@ccdid : UInt16, @csr : Bytes, @nonce_signature : Bytes); end
        end

        struct ProvisionClientCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter ccdid : UInt16
          @[::TLV::Field(tag: 1)]
          getter client_certificate : Bytes
          @[::TLV::Field(tag: 2)]
          getter intermediate_certificates : Array(Bytes)

          def initialize(@ccdid : UInt16, @client_certificate : Bytes, @intermediate_certificates : Array(Bytes)); end
        end

        struct FindClientCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0, optional: false)]
          getter ccdid : UInt16?

          def initialize(@ccdid : UInt16?); end
        end

        struct FindClientCertificateResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter certificate_details : Array(ClientCertificateDetail)

          def initialize(@certificate_details : Array(ClientCertificateDetail)); end
        end

        struct LookupClientCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter fingerprint : Bytes

          def initialize(@fingerprint : Bytes); end
        end

        struct LookupClientCertificateResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter ccdid : UInt16

          def initialize(@ccdid : UInt16); end
        end

        struct RemoveClientCertificateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter ccdid : UInt16

          def initialize(@ccdid : UInt16); end
        end
      end
    end
  end
end
