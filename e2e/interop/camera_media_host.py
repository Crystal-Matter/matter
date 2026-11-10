#!/usr/bin/env python3
"""Optional test media host: synthetic H.264 video over real ICE/DTLS/SRTP.

The Crystal library owns Matter signaling and session scope. This process owns
the media engine and synthetic frame source used only by the GitHub E2E test.
"""

import asyncio
from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from aiortc.rtcrtpsender import RTCRtpSender
from av import VideoFrame

PORT = 18753
WIDTH = 320
HEIGHT = 180
peers = {}


class PatternTrack(VideoStreamTrack):
    def __init__(self):
        super().__init__()
        self.frames = 0

    async def recv(self):
        pts, time_base = await self.next_timestamp()
        frame = VideoFrame(width=WIDTH, height=HEIGHT, format="yuv420p")
        luminance = 76 if self.frames % 2 == 0 else 180
        frame.planes[0].update(bytes([luminance]) * (WIDTH * HEIGHT))
        frame.planes[1].update(bytes([85]) * (WIDTH * HEIGHT // 4))
        frame.planes[2].update(bytes([255]) * (WIDTH * HEIGHT // 4))
        frame.pts = pts
        frame.time_base = time_base
        self.frames += 1
        return frame


async def offer(request):
    session_id = (await request.json())["session_id"]
    if session_id in peers:
        raise web.HTTPConflict(text="duplicate session")
    pc = RTCPeerConnection()
    track = PatternTrack()
    sender = pc.addTrack(track)
    transceiver = next(t for t in pc.getTransceivers() if t.sender == sender)
    codecs = [codec for codec in RTCRtpSender.getCapabilities("video").codecs
              if codec.mimeType.lower() == "video/h264"]
    if not codecs:
        raise web.HTTPServiceUnavailable(text="H.264 codec unavailable")
    transceiver.setCodecPreferences(codecs)
    peers[session_id] = (pc, track)
    await pc.setLocalDescription(await pc.createOffer())
    return web.json_response({"sdp": pc.localDescription.sdp})


async def answer(request):
    body = await request.json()
    pc, _track = peers[body["session_id"]]
    await pc.setRemoteDescription(RTCSessionDescription(sdp=body["sdp"], type="answer"))
    return web.json_response({"state": pc.connectionState})


async def end(request):
    session_id = (await request.json())["session_id"]
    entry = peers.pop(session_id, None)
    if entry:
        await entry[0].close()
    return web.json_response({"ended": entry is not None})


async def state(request):
    return web.json_response({str(key): {"connection": pc.connectionState, "frames": track.frames}
                              for key, (pc, track) in peers.items()})


async def shutdown(app):
    await asyncio.gather(*(pc.close() for pc, _track in peers.values()))
    peers.clear()


app = web.Application()
app.add_routes([web.post("/offer", offer), web.post("/answer", answer),
                web.post("/end", end), web.get("/state", state)])
app.on_shutdown.append(shutdown)

if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=PORT, access_log=None)
