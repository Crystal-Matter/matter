module Matter
  module Protocol
    # The protocol a message belongs to, carried in its payload header.
    enum ProtocolId : UInt16
      SecureChannel             = 0x0000
      InteractionModel          = 0x0001
      Bdx                       = 0x0002
      UserDirectedCommissioning = 0x0003
    end

    # Secure Channel message types (Matter spec 4.10).
    enum SecureChannelMessageType : UInt8
      StandaloneAck      = 0x10
      PbkdfParamRequest  = 0x20
      PbkdfParamResponse = 0x21
      PasePake1          = 0x22
      PasePake2          = 0x23
      PasePake3          = 0x24
      CaseSigma1         = 0x30
      CaseSigma2         = 0x31
      CaseSigma3         = 0x32
      CaseSigma2Resume   = 0x33
      StatusReport       = 0x40
    end
  end
end
