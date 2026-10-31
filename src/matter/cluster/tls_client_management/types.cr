require "tlv"

module Matter
  module Cluster
    class TlsClientManagement < Base
      enum StatusCode : UInt8
        EndpointAlreadyInstalled  = 0x02
        RootCertificateNotFound   = 0x03
        ClientCertificateNotFound = 0x04
        EndpointInUse             = 0x05
        InvalidTime               = 0x06
      end

      module Tlv
        struct Endpoint
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter endpoint_id : UInt16
          @[::TLV::Field(tag: 1)]
          getter hostname : Bytes
          @[::TLV::Field(tag: 2)]
          getter port : UInt16
          @[::TLV::Field(tag: 3)]
          getter caid : UInt16
          @[::TLV::Field(tag: 4, optional: false)]
          getter ccdid : UInt16?
          @[::TLV::Field(tag: 5)]
          getter reference_count : UInt8
          @[::TLV::Field(tag: 254)]
          getter fabric_index : UInt8

          def initialize(@endpoint_id : UInt16, @hostname : Bytes, @port : UInt16,
                         @caid : UInt16, @ccdid : UInt16?, @reference_count : UInt8,
                         @fabric_index : UInt8); end
        end

        struct ProvisionEndpointRequest
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter hostname : Bytes
          @[::TLV::Field(tag: 1)]
          getter port : UInt16
          @[::TLV::Field(tag: 2)]
          getter caid : UInt16
          @[::TLV::Field(tag: 3, optional: false)]
          getter ccdid : UInt16?
          @[::TLV::Field(tag: 4, optional: false)]
          getter endpoint_id : UInt16?

          def initialize(@hostname : Bytes, @port : UInt16, @caid : UInt16,
                         @ccdid : UInt16?, @endpoint_id : UInt16?); end
        end

        struct ProvisionEndpointResponse
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter endpoint_id : UInt16

          def initialize(@endpoint_id : UInt16); end
        end

        struct FindEndpointRequest
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter endpoint_id : UInt16

          def initialize(@endpoint_id : UInt16); end
        end

        struct FindEndpointResponse
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter endpoint : Endpoint

          def initialize(@endpoint : Endpoint); end
        end

        struct RemoveEndpointRequest
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter endpoint_id : UInt16

          def initialize(@endpoint_id : UInt16); end
        end
      end
    end
  end
end
