/** Matter.js Camera Requestor and independent Chromium WebRTC media receiver. */
import { Endpoint, Seconds, ServerNode } from "@matter/main";
import { CameraControllerDevice } from "@matter/main/devices/camera-controller";
import { CameraAvStreamManagementClient } from "@matter/main/behaviors/camera-av-stream-management";
import { WebRtcTransportProviderClient } from "@matter/main/behaviors/web-rtc-transport-provider";
import { WebRtcTransportRequestorServer } from "@matter/main/behaviors/web-rtc-transport-requestor";
import { CameraAvStreamManagement } from "@matter/main/clusters/camera-av-stream-management";
import { EndpointNumber, StreamUsage } from "@matter/main/types";
import { chromium } from "playwright";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const [passcodeText, discriminatorText, controlDir] = process.argv.slice(2);
if (!passcodeText || !discriminatorText || !controlDir) throw new Error("setup and control directory required");
const browser = await chromium.launch({ channel: "chrome", headless: true,
    args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required"] });
const page = await browser.newPage();
page.on("console", message => console.log("Browser:", message.text()));
await page.goto("about:blank");
const controller = await ServerNode.create(ServerNode.RootEndpointWithoutGroupcast, {
    id: "camera-media-requestor", network: { port: 5562, tcp: true },
});
const requestor = new Endpoint(CameraControllerDevice, { id: "camera-controller" });
await controller.add(requestor);
let provider: any;
let offerError: Error | undefined;
let ended = false;
let endReason: number | undefined;
let expectedSessionId = 0;
let installedOfferSessionId = -1;
const PRIVACY_MODE_END_REASON = 11;

async function waitFor(condition: () => Promise<boolean> | boolean, description: string) {
    for (let n = 0; n < 300; n++) {
        if (offerError) throw offerError;
        if (await condition()) return;
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error(`Timed out waiting for ${description}`);
}

try {
    await controller.start();
    await requestor.act(agent => {
        const server = agent.get(WebRtcTransportRequestorServer);
        server.events.offer.on((_session, args) => {
            void (async () => {
                console.log("Matter.js received Camera Offer", args.webRtcSessionId, args.sdp.length);
                if (args.webRtcSessionId !== expectedSessionId || !args.sdp.includes("m=video") ||
                    (expectedSessionId === 0 && !args.sdp.includes("m=audio"))) {
                    throw new Error("Camera Offer has no matching audio/video media tracks");
                }
                const answer = await page.evaluate(async (sdp: string) => {
                    const scope = globalThis as any;
                    const pc = new scope.RTCPeerConnection({ iceServers: [] });
                    pc.oniceconnectionstatechange = () => console.log("ICE state", pc.iceConnectionState);
                    pc.onconnectionstatechange = () => console.log("Peer state", pc.connectionState);
                    scope.cameraPeer = pc;
                    scope.decodedFrames = 0;
                    scope.frameDimensions = "";
                    pc.ontrack = (event: any) => {
                        if (event.track.kind === "audio") {
                            console.log("Audio track received");
                            const audioElement = scope.document.createElement("audio");
                            audioElement.autoplay = true;
                            audioElement.volume = 0.01;
                            audioElement.srcObject = new scope.MediaStream([event.track]);
                            scope.document.body.append(audioElement);
                            void audioElement.play().then(() => console.log("Audio element playing"),
                                (error: Error) => console.log("Audio element failed", error.message));
                            const context = new scope.AudioContext({ sampleRate: 48000 });
                            const source = context.createMediaStreamSource(new scope.MediaStream([event.track]));
                            const analyser = context.createAnalyser();
                            analyser.fftSize = 2048;
                            const silentOutput = context.createGain();
                            silentOutput.gain.value = 0;
                            source.connect(analyser).connect(silentOutput).connect(context.destination);
                            scope.audioContext = context;
                            scope.audioEnergy = 0;
                            const samples = new Float32Array(analyser.fftSize);
                            scope.audioSampleTimer = scope.setInterval(() => {
                                analyser.getFloatTimeDomainData(samples);
                                scope.audioEnergy += samples.reduce((sum, sample) => sum + sample * sample, 0);
                            }, 50);
                            void context.resume();
                            return;
                        }
                        const video = scope.document.createElement("video");
                        video.autoplay = true;
                        video.muted = true;
                        video.srcObject = new scope.MediaStream([event.track]);
                        scope.document.body.append(video);
                        const count = () => {
                            scope.decodedFrames++;
                            scope.frameDimensions = video.videoWidth + "x" + video.videoHeight;
                            video.requestVideoFrameCallback(count);
                        };
                        video.requestVideoFrameCallback(count);
                        void video.play();
                    };
                    await pc.setRemoteDescription({ type: "offer", sdp });
                    console.log("Remote Offer installed", pc.iceConnectionState);
                    await pc.setLocalDescription(await pc.createAnswer());
                    console.log("Local Answer installed", pc.iceGatheringState);
                    const mediaLine = pc.localDescription.sdp.split("\r\n").find((line: string) => line.startsWith("m=video"));
                    console.log("Answer media line", mediaLine);
                    if (!mediaLine || mediaLine.startsWith("m=video 0 ")) {
                        throw new Error("Browser rejected H.264 video media section");
                    }
                    if (pc.iceGatheringState !== "complete") {
                        await new Promise<void>(resolve => {
                            pc.addEventListener("icegatheringstatechange", () => {
                                if (pc.iceGatheringState === "complete") resolve();
                            });
                        });
                    }
                    console.log("ICE gathering complete", pc.localDescription.sdp.length);
                    return pc.localDescription.sdp as string;
                }, args.sdp);
                installedOfferSessionId = args.webRtcSessionId;
                console.log("Matter.js sending Answer", answer.length);
                await provider.provideAnswer({ webRtcSessionId: expectedSessionId, sdp: answer });
                console.log("Matter.js Answer accepted");
            })().catch(error => { offerError = error instanceof Error ? error : new Error(String(error)); });
        });
        server.events.end.on((_session, reason) => { ended = true; endReason = reason; });
    });
    const camera = await controller.peers.commission({
        id: "camera", passcode: Number(passcodeText), discriminator: Number(discriminatorText), timeout: Seconds(60),
    });
    await camera.start();
    const address = camera.peerAddress;
    const endpoint = camera.parts.get(1);
    if (!address || !endpoint) throw new Error("Commissioned Camera endpoint/address missing");
    const audioStream = await endpoint.commandsOf(CameraAvStreamManagementClient).audioStreamAllocate({
        streamUsage: StreamUsage.LiveView, audioCodec: CameraAvStreamManagement.AudioCodec.Opus,
        channelCount: 1, sampleRate: 48000, bitRate: 64000, bitDepth: 16,
    });
    const stream = await endpoint.commandsOf(CameraAvStreamManagementClient).videoStreamAllocate({
        streamUsage: StreamUsage.LiveView, videoCodec: CameraAvStreamManagement.VideoCodec.H264,
        minFrameRate: 15, maxFrameRate: 30,
        minResolution: { width: 320, height: 180 }, maxResolution: { width: 1280, height: 720 },
        minBitRate: 200000, maxBitRate: 1000000, keyFrameInterval: 30,
    });
    provider = endpoint.commandsOf(WebRtcTransportProviderClient);
    await requestor.act(agent => agent.get(WebRtcTransportRequestorServer).upsertSession({
        id: 0, peerNodeId: address.nodeId, peerEndpointId: EndpointNumber(1),
        streamUsage: StreamUsage.LiveView, metadataEnabled: false,
        audioStreams: [audioStream.audioStreamId], videoStreams: [stream.videoStreamId],
        fabricIndex: address.fabricIndex,
    }));
    const response = await provider.solicitOffer({
        streamUsage: StreamUsage.LiveView, originatingEndpointId: EndpointNumber(1),
        audioStreams: [audioStream.audioStreamId], videoStreams: [stream.videoStreamId],
    });
    if (response.webRtcSessionId !== 0) throw new Error("Unexpected Provider session ID");
    await waitFor(async () => await page.evaluate(() => (globalThis as any).decodedFrames >= 2), "two decoded frames");
    await waitFor(async () => await page.evaluate(async () => {
        const pc = (globalThis as any).cameraPeer as RTCPeerConnection;
        const audio = pc.getReceivers().find(receiver => receiver.track.kind === "audio");
        if (!audio) return false;
        const stats = await audio.getStats();
        return [...stats.values()].some((entry: any) => entry.type === "inbound-rtp" &&
            entry.kind === "audio" && entry.packetsReceived >= 2) &&
            (globalThis as any).audioEnergy > 1;
    }), "decoded Opus audio samples");
    const audioEnergy = await page.evaluate(() => (globalThis as any).audioEnergy);
    console.log(`Chrome decoded synthetic Opus audio energy ${audioEnergy}`);
    const dimensions = await page.evaluate(() => (globalThis as any).frameDimensions);
    if (dimensions !== "320x180") throw new Error(`Unexpected decoded frame dimensions: ${dimensions}`);
    writeFileSync(join(controlDir, "end-0"), "end");
    await waitFor(() => ended, "Matter Requestor End");
    await waitFor(async () => {
        const state = await (await fetch("http://127.0.0.1:18753/state")).json() as Record<string, unknown>;
        return !("0" in state);
    }, "host WebRTC peer teardown");
    // Allow an already-decoded frame to drain, then require delivery to stop.
    await new Promise(resolve => setTimeout(resolve, 1000));
    const count = await page.evaluate(() => (globalThis as any).decodedFrames);
    await new Promise(resolve => setTimeout(resolve, 500));
    if (await page.evaluate(() => (globalThis as any).decodedFrames) !== count) {
        throw new Error("Video frames continued after End");
    }
    await page.evaluate(async () => {
        const scope = globalThis as any;
        scope.clearInterval(scope.audioSampleTimer);
        await scope.audioContext.close();
        scope.cameraPeer.close();
    });
    console.log(`PASS: Matter.js Requestor received ${count} decoded WebRTC H.264 frames at ${dimensions}; End stopped media`);

    // A second live session must end through the Camera privacy path, without
    // the explicit host hangup control used above.
    expectedSessionId = 1;
    ended = false;
    endReason = undefined;
    await requestor.act(agent => agent.get(WebRtcTransportRequestorServer).upsertSession({
        id: 1, peerNodeId: address.nodeId, peerEndpointId: EndpointNumber(1),
        streamUsage: StreamUsage.LiveView, metadataEnabled: false,
        videoStreams: [stream.videoStreamId], fabricIndex: address.fabricIndex,
    }));
    const privacySession = await provider.solicitOffer({
        streamUsage: StreamUsage.LiveView, originatingEndpointId: EndpointNumber(1),
        videoStreams: [stream.videoStreamId],
    });
    if (privacySession.webRtcSessionId !== 1) throw new Error("Unexpected privacy test session ID");
    await waitFor(async () => installedOfferSessionId === 1 &&
        await page.evaluate(() => (globalThis as any).decodedFrames >= 2),
        "two decoded frames before privacy");
    const privacyFramesBeforeEnd = await page.evaluate(() => (globalThis as any).decodedFrames);
    const privacyDimensions = await page.evaluate(() => (globalThis as any).frameDimensions);
    if (privacyDimensions !== "320x180") {
        throw new Error(`Unexpected privacy session frame dimensions: ${privacyDimensions}`);
    }
    console.log(`Privacy session decoded ${privacyFramesBeforeEnd} frames at ${privacyDimensions} before End`);
    writeFileSync(join(controlDir, "privacy-1"), "privacy");
    await waitFor(() => ended, "Matter Requestor PrivacyMode End");
    if (endReason !== PRIVACY_MODE_END_REASON) {
        throw new Error(`Expected PrivacyMode End reason, got ${endReason}`);
    }
    await waitFor(async () => {
        const state = await (await fetch("http://127.0.0.1:18753/state")).json() as Record<string, unknown>;
        return !("1" in state);
    }, "privacy host WebRTC peer teardown");
    await new Promise(resolve => setTimeout(resolve, 1000));
    const privateCount = await page.evaluate(() => (globalThis as any).decodedFrames);
    if (privateCount < 2) throw new Error(`Privacy session decoded only ${privateCount} frames`);
    await new Promise(resolve => setTimeout(resolve, 500));
    if (await page.evaluate(() => (globalThis as any).decodedFrames) !== privateCount) {
        throw new Error("Video frames continued after privacy");
    }
    await page.evaluate(() => (globalThis as any).cameraPeer.close());
    console.log(`PASS: Soft livestream privacy ended Matter session with PrivacyMode and stopped ${privateCount} decoded frames`);
} finally {
    await controller.close();
    await browser.close();
}
