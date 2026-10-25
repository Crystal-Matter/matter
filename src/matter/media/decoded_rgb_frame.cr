require "../error"

module Matter
  module Media
    # A decoded, tightly packed RGB24 frame supplied by the host camera.
    # Encoded stream IDs and signaling alone are not media frames.
    struct DecodedRgbFrame
      CHANNELS         =         3
      MAX_FRAME_PIXELS = 8_294_400

      getter width : UInt16
      getter height : UInt16
      getter pixels : Bytes

      def initialize(@width : UInt16, @height : UInt16, pixels : Bytes)
        pixel_count = @width.to_i64 * @height.to_i64
        if pixel_count.zero? || pixel_count > MAX_FRAME_PIXELS ||
           pixels.size != pixel_count * CHANNELS
          raise ArgumentError.new("Decoded RGB24 frame dimensions or byte count are invalid")
        end
        @pixels = pixels.dup
      end
    end
  end
end
