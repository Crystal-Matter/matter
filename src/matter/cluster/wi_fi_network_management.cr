require "./cluster"

module Matter
  module Cluster
    # Opt-in Matter 1.6 Wi-Fi Network Management server (0x0451).
    #
    # A network infrastructure manager supplies its current credentials via
    # `update_credentials`. The host owns durable credential storage and must
    # repopulate the cluster after a restart. Secrets are never placed in the
    # cluster's ordinary Storage::Document persistence record.
    class WiFiNetworkManagement < Base
      cluster 0x0451, revision: 1, persist_state: false

      MIN_SSID_LENGTH       =  1
      MAX_SSID_LENGTH       = 32
      MIN_PASSPHRASE_LENGTH =  8
      MAX_PASSPHRASE_LENGTH = 64
      MAX_TEXT_PASSPHRASE   = 63

      struct NetworkPassphraseResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property passphrase : Bytes

        def initialize(@passphrase : Bytes)
        end
      end

      attribute 0x0000, :ssid, Bytes, nullable: true
      attribute 0x0001, :passphrase_surrogate, UInt64, nullable: true, read_access: :manage

      command 0x00, :network_passphrase_request, response: NetworkPassphraseResponse,
        response_id: 0x01, access: :manage

      @passphrase : Bytes? = nil
      @last_surrogate : UInt64? = nil

      # The host persists the surrogate alongside its credential. Reuse that
      # value when restoring unchanged credentials after a restart; supply a
      # different value only when the passphrase changes. Input is copied.
      # A valid WPA-Personal passphrase is 8–63 bytes, or a 64-byte hex PSK.
      def update_credentials(ssid : Bytes, passphrase : Bytes, surrogate : UInt64) : Nil
        validate_credentials(ssid, passphrase)
        old_passphrase = @passphrase
        passphrase_changed = old_passphrase != passphrase
        if passphrase_changed && @last_surrogate == surrogate
          raise ConfigurationError.new("Wi-Fi passphrase change requires a new durable surrogate")
        elsif !passphrase_changed && @passphrase_surrogate != surrogate
          raise ConfigurationError.new("Unchanged Wi-Fi passphrase must retain its surrogate")
        end

        self.ssid = ssid.dup if @ssid != ssid
        return unless passphrase_changed

        @passphrase = passphrase.dup
        old_passphrase.try(&.fill(0_u8))
        @last_surrogate = surrogate
        self.passphrase_surrogate = surrogate
      end

      def clear_credentials : Nil
        return unless @passphrase

        @passphrase.try(&.fill(0_u8))
        @passphrase = nil
        self.ssid = nil
        self.passphrase_surrogate = nil
      end

      def network_passphrase_request : InteractionModel::Status | NetworkPassphraseResponse
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        passphrase = @passphrase
        return InteractionModel::Status.invalid_in_state unless passphrase

        NetworkPassphraseResponse.new(passphrase.dup)
      end

      private def validate_credentials(ssid : Bytes, passphrase : Bytes) : Nil
        unless ssid.size.in?(MIN_SSID_LENGTH..MAX_SSID_LENGTH)
          raise ConfigurationError.new("Wi-Fi SSID must contain 1–32 bytes")
        end

        valid_text = passphrase.size.in?(MIN_PASSPHRASE_LENGTH..MAX_TEXT_PASSPHRASE)
        valid_psk = passphrase.size == MAX_PASSPHRASE_LENGTH && passphrase.all? do |byte|
          byte.in?('0'.ord..'9'.ord) || byte.in?('A'.ord..'F'.ord) || byte.in?('a'.ord..'f'.ord)
        end
        raise ConfigurationError.new("Wi-Fi passphrase must be 8–63 bytes or a 64-digit hex PSK") unless valid_text || valid_psk
      end
    end
  end
end
