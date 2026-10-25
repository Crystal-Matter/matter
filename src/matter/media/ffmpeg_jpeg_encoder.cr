require "./decoded_rgb_frame"

module Matter
  module Media
    # Optional host adapter. Applications explicitly require this file and
    # provide an ffmpeg executable when they have a decoded RGB camera source.
    class FfmpegJpegEncoder
      JPEG_START = Bytes[0xFF, 0xD8]
      JPEG_END   = Bytes[0xFF, 0xD9]

      def initialize(@executable : String = "ffmpeg")
        raise ArgumentError.new("FFmpeg executable is empty") if @executable.empty?
      end

      def encode(frame : DecodedRgbFrame, quality : UInt8) : Bytes
        raise ArgumentError.new("JPEG quality must be between 1 and 100") unless quality.in?(1_u8..100_u8)

        # FFmpeg's MJPEG quantizer is inverted: 2 is high quality, 31 is low.
        quantizer = 31 - ((quality.to_i - 1) * 29 // 99)
        output = IO::Memory.new
        diagnostics = IO::Memory.new
        args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "rawvideo",
                "-pixel_format", "rgb24", "-video_size", "#{frame.width}x#{frame.height}",
                "-i", "pipe:0", "-frames:v", "1", "-q:v", quantizer.to_s,
                "-f", "mjpeg", "pipe:1"]
        status = Process.run(@executable, args,
          input: IO::Memory.new(frame.pixels), output: output, error: diagnostics)
        unless status.success?
          raise Matter::ProtocolError.new("FFmpeg JPEG encoding failed: #{diagnostics.to_s.strip}")
        end
        bytes = output.to_slice
        unless bytes.size >= 4 && bytes[0, 2] == JPEG_START &&
               bytes[bytes.size - 2, 2] == JPEG_END
          raise Matter::ProtocolError.new("FFmpeg did not return a JPEG image")
        end
        bytes.dup
      rescue ex : IO::Error
        raise Matter::ProtocolError.new("FFmpeg JPEG encoder is unavailable", cause: ex)
      end
    end
  end
end
