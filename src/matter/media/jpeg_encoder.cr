require "crimage"
require "./decoded_rgb_frame"

module Matter
  module Media
    # Optional pure-Crystal adapter for an RGB24 camera source.
    class JpegEncoder
      JPEG_START = Bytes[0xFF, 0xD8]
      JPEG_END   = Bytes[0xFF, 0xD9]

      def encode(frame : DecodedRgbFrame, quality : UInt8) : Bytes
        raise ArgumentError.new("JPEG quality must be between 1 and 100") unless quality.in?(1_u8..100_u8)

        rgba_pixels = Bytes.new(frame.width.to_i * frame.height.to_i * 4)
        rgb_pixels = frame.pixels
        source = 0
        target = 0
        while source < rgb_pixels.size
          rgba_pixels[target] = rgb_pixels[source]
          rgba_pixels[target + 1] = rgb_pixels[source + 1]
          rgba_pixels[target + 2] = rgb_pixels[source + 2]
          rgba_pixels[target + 3] = 255_u8
          source += DecodedRgbFrame::CHANNELS
          target += 4
        end

        image = CrImage::RGBA.from_buffer(rgba_pixels, frame.width.to_i, frame.height.to_i)
        output = IO::Memory.new
        CrImage::JPEG.write(output, image, quality.to_i)
        bytes = output.to_slice
        unless bytes.size >= 4 && bytes[0, 2] == JPEG_START &&
               bytes[bytes.size - 2, 2] == JPEG_END
          raise Matter::ProtocolError.new("JPEG encoder did not return a JPEG image")
        end
        bytes.dup
      rescue ex : CrImage::JPEG::FormatError
        raise Matter::ProtocolError.new("JPEG encoding failed: #{ex.message}", cause: ex)
      end
    end
  end
end
