require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Matter 1.6 Application Basic (0x050D) describes a Content App endpoint.
    # Its identity is fixed for the lifetime of the endpoint; Status is a
    # runtime observation supplied by the host application.
    class ApplicationBasic < Base
      cluster 0x050D, revision: 1

      APPLICATION_NAME_MAX_LENGTH    = 256
      APPLICATION_VERSION_MAX_LENGTH =  32
      VENDOR_NAME_MAX_LENGTH         =  32

      enum ApplicationStatus : UInt8
        Stopped               = 0
        ActiveVisibleFocus    = 1
        ActiveHidden          = 2
        ActiveVisibleNotFocus = 3
      end

      struct Application
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter catalog_vendor_id : UInt16

        @[TLV::Field(tag: 1)]
        getter application_id : String

        def initialize(@catalog_vendor_id : UInt16, @application_id : String)
        end
      end

      attribute 0x0000, :vendor_name, String,
        computed: true, fixed: true, optional: true, present_if: :vendor_name_present?
      attribute 0x0001, :vendor_id, UInt16,
        computed: true, fixed: true, optional: true, present_if: :vendor_id_present?
      attribute 0x0002, :application_name, String, computed: true, fixed: true
      attribute 0x0003, :product_id, UInt16,
        computed: true, fixed: true, optional: true, present_if: :product_id_present?
      attribute 0x0004, :application, Application, computed: true, fixed: true
      attribute 0x0005, :status, ApplicationStatus, default: ApplicationStatus::Stopped
      attribute 0x0006, :application_version, String, computed: true, fixed: true
      attribute 0x0007, :allowed_vendor_list, Array(UInt16),
        computed: true, fixed: true, read_access: :administer

      def initialize(endpoint_id : DataType::EndpointNumber, *, @application_name : String,
                     @application : Application, @application_version : String,
                     allowed_vendor_list : Array(UInt16), @vendor_name : String? = nil,
                     @vendor_id : UInt16? = nil, @product_id : UInt16? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_length!(@application_name, APPLICATION_NAME_MAX_LENGTH, "ApplicationName")
        validate_length!(@application_version, APPLICATION_VERSION_MAX_LENGTH, "ApplicationVersion")
        if name = @vendor_name
          validate_length!(name, VENDOR_NAME_MAX_LENGTH, "VendorName")
        end
        @allowed_vendor_list = allowed_vendor_list.dup
      end

      def vendor_name : String
        @vendor_name || raise Matter::ConfigurationError.new("VendorName is not configured")
      end

      def vendor_id : UInt16
        @vendor_id || raise Matter::ConfigurationError.new("VendorID is not configured")
      end

      def application_name : String
        @application_name
      end

      def product_id : UInt16
        @product_id || raise Matter::ConfigurationError.new("ProductID is not configured")
      end

      def application : Application
        @application
      end

      def application_version : String
        @application_version
      end

      # Return a copy so callers cannot mutate a fixed on-wire list in place.
      def allowed_vendor_list : Array(UInt16)
        @allowed_vendor_list.dup
      end

      # A Content App reports its running state through the host API. It is
      # deliberately not persisted: a newly started process is stopped until
      # the host reports otherwise.
      def update_status(value : ApplicationStatus) : Nil
        self.status = value
      end

      private def vendor_name_present? : Bool
        !@vendor_name.nil?
      end

      private def vendor_id_present? : Bool
        !@vendor_id.nil?
      end

      private def product_id_present? : Bool
        !@product_id.nil?
      end

      private def validate_length!(value : String, maximum : Int32, name : String) : Nil
        return if value.bytesize <= maximum
        raise ArgumentError.new("#{name} must be at most #{maximum} bytes")
      end
    end
  end
end
