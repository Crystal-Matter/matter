require "./cluster"

module Matter
  module Cluster
    # Node locale preferences and the fixed list of locale identifiers it supports.
    class LocalizationConfiguration < Base
      cluster 0x002B, revision: 1

      MAX_LOCALE_LENGTH   = 35
      MAX_SUPPORTED_COUNT = 32

      attribute 0x0000, :active_locale, String, default: "en-US", writable: true,
        write_access: :manage, max_length: MAX_LOCALE_LENGTH, persist: true
      attribute 0x0001, :supported_locales, Array(String),
        default: [] of String, fixed: true

      before_write :active_locale do |locale|
        InteractionModel::Status.constraint_error unless @supported_locales.includes?(locale)
      end

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @active_locale : String,
                     @supported_locales : Array(String))
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("supported_locales must contain 1 to #{MAX_SUPPORTED_COUNT} entries") if @supported_locales.empty? || @supported_locales.size > MAX_SUPPORTED_COUNT
        raise ArgumentError.new("supported_locales must not contain duplicates") unless @supported_locales.uniq.size == @supported_locales.size
        if @supported_locales.any? { |locale| locale.empty? || locale.bytesize > MAX_LOCALE_LENGTH }
          raise ArgumentError.new("supported_locales entries must contain 1 to #{MAX_LOCALE_LENGTH} bytes")
        end
        raise ArgumentError.new("active_locale must be in supported_locales") unless @supported_locales.includes?(@active_locale)
        @supported_locales = @supported_locales.dup
      end
    end
  end
end
