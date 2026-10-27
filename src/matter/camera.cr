# Optional host-side Camera signaling adapters. `require "matter"` remains
# device-only; applications that use an outbound Requestor client opt in here.
require "../matter"
require "./controller/webrtc_requestor_client"
require "./camera/signaling_sink"
