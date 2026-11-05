/** Independent Matter.js Requestor signaling against the Crystal Camera test fixture.
 * SDP and ICE are deterministic protocol probes. This does not create a media track.
 */
import { Endpoint, Seconds, ServerNode } from "@matter/main";
import { CameraControllerDevice } from "@matter/main/devices/camera-controller";
import { CameraAvStreamManagementClient } from "@matter/main/behaviors/camera-av-stream-management";
import { WebRtcTransportProviderClient } from "@matter/main/behaviors/web-rtc-transport-provider";
import { WebRtcTransportRequestorServer } from "@matter/main/behaviors/web-rtc-transport-requestor";
import { CameraAvStreamManagement } from "@matter/main/clusters/camera-av-stream-management";
import { EndpointNumber, NodeId, StreamUsage } from "@matter/main/types";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const [passcodeText, discriminatorText, controlDir] = process.argv.slice(2);
if (!passcodeText || !discriminatorText || !controlDir) {
    throw new Error("passcode, full discriminator and control directory are required");
}
const controller = await ServerNode.create(ServerNode.RootEndpointWithoutGroupcast, {
    id: "camera-signaling-requestor", network: { port: 5561 },
});
const requestor = new Endpoint(CameraControllerDevice, { id: "camera-controller" });
await controller.add(requestor);
const received: string[] = [];
async function observeRequestor() {
    await requestor.act(agent => {
        const server = agent.get(WebRtcTransportRequestorServer);
        server.events.offer.on((_session, args) => {
            if (!args.sdp.startsWith("v=0") || args.webRtcSessionId !== 1) throw new Error("bad Offer");
            received.push("offer");
        });
        server.events.answer.on((_session, sdp) => {
            if (!sdp.startsWith("v=0")) throw new Error("bad Answer");
            received.push("answer");
        });
        server.events.iceCandidates.on((_session, candidates) => {
            if (candidates.length !== 1 || !candidates[0].candidate.startsWith("candidate:")) {
                throw new Error("bad ICE candidates");
            }
            received.push("ice");
        });
        server.events.end.on((_session, _reason) => {
            received.push("end");
        });
        server.events.refused.on((_signal, id, _peer) => {
            if (id !== 0) throw new Error("unexpected refused session");
            received.push("refused");
        });
    });
}

async function waitFor(name: string) {
    for (let n = 0; n < 200; n++) {
        if (received.includes(name)) return;
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error(`Timed out waiting for ${name}; received ${received.join(",")}`);
}

try {
    await controller.start();
    await observeRequestor();
    const camera = await controller.peers.commission({
        id: "camera", passcode: Number(passcodeText), discriminator: Number(discriminatorText),
        timeout: Seconds(60),
    });
    await camera.start();
    const address = camera.peerAddress;
    if (!address) throw new Error("Commissioned Camera has no peer address");
    const endpoint = camera.parts.get(1);
    if (!endpoint) throw new Error("Commissioned Camera endpoint is missing");
    const cameraAv = endpoint.commandsOf(CameraAvStreamManagementClient);
    const provider = endpoint.commandsOf(WebRtcTransportProviderClient);
    const stream = await cameraAv.videoStreamAllocate({
        streamUsage: StreamUsage.LiveView,
        videoCodec: CameraAvStreamManagement.VideoCodec.H264,
        minFrameRate: 15,
        maxFrameRate: 30,
        minResolution: { width: 320, height: 180 },
        maxResolution: { width: 1280, height: 720 },
        minBitRate: 200000,
        maxBitRate: 1000000,
        keyFrameInterval: 30,
    });
    const videoStreamId = stream.videoStreamId;
    const session = (id: number, peerNodeId = address.nodeId) => ({
        id, peerNodeId, peerEndpointId: EndpointNumber(1), streamUsage: StreamUsage.LiveView,
        metadataEnabled: false, videoStreams: [videoStreamId],
        fabricIndex: address.fabricIndex,
    });
    await requestor.act(agent => agent.get(WebRtcTransportRequestorServer)
        .upsertSession(session(0, NodeId(address.nodeId + 1n))));
    const first = await provider.provideOffer({
        webRtcSessionId: null, sdp: "v=0\r\no=matterjs 1 1 IN IP4 127.0.0.1\r\ns=signaling-only\r\nt=0 0\r\n",
        streamUsage: StreamUsage.LiveView, originatingEndpointId: EndpointNumber(1),
        videoStreams: [videoStreamId],
    });
    if (first.webRtcSessionId !== 0) throw new Error(`Expected session 0, got ${first.webRtcSessionId}`);
    await waitFor("refused");
    await requestor.act(agent => agent.get(WebRtcTransportRequestorServer).removeSession(session(0, NodeId(address.nodeId + 1n))));

    await requestor.act(agent => agent.get(WebRtcTransportRequestorServer).upsertSession(session(1)));
    const offered = await provider.solicitOffer({
        streamUsage: StreamUsage.LiveView, originatingEndpointId: EndpointNumber(1),
        videoStreams: [videoStreamId],
    });
    if (offered.webRtcSessionId !== 1) throw new Error(`Expected session 1, got ${offered.webRtcSessionId}`);
    await waitFor("offer");
    await provider.provideAnswer({ webRtcSessionId: 1,
        sdp: "v=0\r\no=matterjs 2 2 IN IP4 127.0.0.1\r\ns=signaling-only\r\nt=0 0\r\n" });
    await provider.provideIceCandidates({ webRtcSessionId: 1, iceCandidates: [{
        candidate: "candidate:2 1 UDP 1 127.0.0.1 1235 typ host", sdpMid: "0", sdpmLineIndex: 0,
    }] });
    await waitFor("ice");
    writeFileSync(join(controlDir, "end-1"), "end");
    await waitFor("end");
    received.splice(received.indexOf("end"), 1);
    await requestor.act(agent => agent.get(WebRtcTransportRequestorServer).upsertSession(session(2)));
    const answered = await provider.provideOffer({
        webRtcSessionId: null, sdp: "v=0\r\no=matterjs 3 3 IN IP4 127.0.0.1\r\ns=signaling-only\r\nt=0 0\r\n",
        streamUsage: StreamUsage.LiveView, originatingEndpointId: EndpointNumber(1),
        videoStreams: [videoStreamId],
    });
    if (answered.webRtcSessionId !== 2) throw new Error(`Expected session 2, got ${answered.webRtcSessionId}`);
    await waitFor("answer");
    writeFileSync(join(controlDir, "end-2"), "end");
    await waitFor("end");
    const remaining = requestor.stateOf(WebRtcTransportRequestorServer).currentSessions;
    if (remaining.length !== 0) throw new Error(`Requestor still tracks ${remaining.length} sessions`);
    console.log("PASS: independent matter.js Requestor received Offer, Answer, ICE, End, and rejected wrong-peer signaling over CASE");
    console.log("NOTE: deterministic SDP/ICE only; no decoded media was verified");
} finally {
    await controller.close();
}
