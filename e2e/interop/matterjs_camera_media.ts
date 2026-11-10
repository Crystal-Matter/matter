/** Matter.js Camera Requestor and independent Chromium WebRTC video receiver. */
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
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();
await page.goto("about:blank");
const controller = await ServerNode.create(ServerNode.RootEndpointWithoutGroupcast, {
    id: "camera-media-requestor", network: { port: 5562, tcp: true },
});
const requestor = new Endpoint(CameraControllerDevice, { id: "camera-controller" });
await controller.add(requestor);
let provider: any;
let offerError: Error | undefined;
let ended = false;

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
                if (args.webRtcSessionId !== 0 || !args.sdp.includes("m=video")) {
                    throw new Error("Camera Offer has no matching video media track");
                }
                const answer = await page.evaluate(async (sdp: string) => {
                    const scope = globalThis as any;
                    const pc = new scope.RTCPeerConnection({ iceServers: [] });
                    scope.cameraPeer = pc;
                    scope.decodedFrames = 0;
                    scope.frameDimensions = "";
                    pc.ontrack = (event: any) => {
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
                    await pc.setLocalDescription(await pc.createAnswer());
                    if (pc.iceGatheringState !== "complete") {
                        await new Promise<void>(resolve => {
                            pc.addEventListener("icegatheringstatechange", () => {
                                if (pc.iceGatheringState === "complete") resolve();
                            });
                        });
                    }
                    return pc.localDescription.sdp as string;
                }, args.sdp);
                await provider.provideAnswer({ webRtcSessionId: 0, sdp: answer });
            })().catch(error => { offerError = error instanceof Error ? error : new Error(String(error)); });
        });
        server.events.end.on(() => { ended = true; });
    });
    const camera = await controller.peers.commission({
        id: "camera", passcode: Number(passcodeText), discriminator: Number(discriminatorText), timeout: Seconds(60),
    });
    await camera.start();
    const address = camera.peerAddress;
    const endpoint = camera.parts.get(1);
    if (!address || !endpoint) throw new Error("Commissioned Camera endpoint/address missing");
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
        videoStreams: [stream.videoStreamId], fabricIndex: address.fabricIndex,
    }));
    const response = await provider.solicitOffer({
        streamUsage: StreamUsage.LiveView, originatingEndpointId: EndpointNumber(1),
        videoStreams: [stream.videoStreamId],
    });
    if (response.webRtcSessionId !== 0) throw new Error("Unexpected Provider session ID");
    await waitFor(async () => await page.evaluate(() => (globalThis as any).decodedFrames >= 2), "two decoded frames");
    const dimensions = await page.evaluate(() => (globalThis as any).frameDimensions);
    if (dimensions !== "320x180") throw new Error(`Unexpected decoded frame dimensions: ${dimensions}`);
    writeFileSync(join(controlDir, "end-0"), "end");
    await waitFor(() => ended, "Matter Requestor End");
    await page.evaluate(() => (globalThis as any).cameraPeer.close());
    const count = await page.evaluate(() => (globalThis as any).decodedFrames);
    await new Promise(resolve => setTimeout(resolve, 500));
    if (await page.evaluate(() => (globalThis as any).decodedFrames) !== count) {
        throw new Error("Video frames continued after End");
    }
    console.log(`PASS: Matter.js Requestor received ${count} decoded WebRTC H.264 frames at ${dimensions}; End stopped media`);
} finally {
    await controller.close();
    await browser.close();
}
