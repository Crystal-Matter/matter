require "tlv"
require "../storage/record"

module Matter
  module Cluster
    # Shared struct for FixedLabel (0x0040) and UserLabel (0x0041) clusters.
    struct LabelStruct
      include TLV::Serializable
      include Storage::Record

      # Matter Label base cluster constrains both fields to 16 UTF-8 bytes.
      MAX_LENGTH = 16

      @[TLV::Field(tag: 0)]
      property label : String

      @[TLV::Field(tag: 1)]
      property value : String

      def initialize(@label : String, @value : String)
      end

      def valid_lengths? : Bool
        @label.bytesize <= MAX_LENGTH && @value.bytesize <= MAX_LENGTH
      end
    end
  end
end
