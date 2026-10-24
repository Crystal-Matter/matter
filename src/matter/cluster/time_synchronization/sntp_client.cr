require "socket"
require "random/secure"

module Matter
  module Cluster
    class TimeSynchronization
      # Minimal SNTPv4 client for the opt-in NTPClient feature. It does not
      # adjust the host clock; the cluster keeps the accepted time monotonic.
      class SntpClient
        PACKET_SIZE           =                48
        NTP_PORT              =               123
        NTP_TO_MATTER_SECONDS = 3_155_673_600_u64
        RECEIVE_TIMEOUT       = 2.seconds
        REQUEST_HEADER        =           0x23_u8 # LI=0, version=4, mode=client
        SERVER_MODE           =              4_u8
        VERSION_MASK          =           0x38_u8
        VERSION_4             =           0x20_u8
        MODE_MASK             =           0x07_u8
        LEAP_MASK             =           0xC0_u8
        UNSYNCHRONIZED_LEAP   =           0xC0_u8
        MIN_STRATUM           =              1_u8
        MAX_STRATUM           =             15_u8
        FRACTION_SCALE        = 4_294_967_296_u64
        MICROS_PER_SECOND     =     1_000_000_u64

        def self.query(address : String, port : Int32 = NTP_PORT) : UInt64?
          destination = Socket::IPAddress.new(address, port)
          return unless destination.family == Socket::Family::INET6

          token = Random::Secure.random_bytes(8)
          request = Bytes.new(PACKET_SIZE, 0_u8)
          request[0] = REQUEST_HEADER
          request[40, 8].copy_from(token)
          socket = UDPSocket.new(Socket::Family::INET6)
          begin
            socket.read_timeout = RECEIVE_TIMEOUT
            socket.send(request, destination)
            response = Bytes.new(PACKET_SIZE)
            size, sender = socket.receive(response)
            return unless sender == destination
            decode(response[0, size], token)
          ensure
            socket.close
          end
        rescue Socket::Error | IO::TimeoutError
          nil
        end

        def self.decode(response : Bytes, token : Bytes) : UInt64?
          return unless response.size >= PACKET_SIZE && token.size == 8
          return unless response[0] & MODE_MASK == SERVER_MODE
          return unless response[0] & VERSION_MASK == VERSION_4
          return if response[0] & LEAP_MASK == UNSYNCHRONIZED_LEAP
          return unless MIN_STRATUM <= response[1] <= MAX_STRATUM
          return unless response[24, 8] == token

          seconds = 0_u64
          fraction = 0_u64
          4.times do |index|
            seconds = (seconds << 8) | response[40 + index].to_u64
            fraction = (fraction << 8) | response[44 + index].to_u64
          end
          return if seconds < NTP_TO_MATTER_SECONDS
          matter_seconds = seconds - NTP_TO_MATTER_SECONDS
          return if matter_seconds > UInt64::MAX // MICROS_PER_SECOND
          matter_seconds * MICROS_PER_SECOND + fraction * MICROS_PER_SECOND // FRACTION_SCALE
        end
      end
    end
  end
end
