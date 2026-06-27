// Records an appload-rmstream WebSocket feed to an mp4.
// Mirrors the browser client: keyframe (packet 3) = full PNG, then deflate-raw
// delta packets (packet 1) patch the RGBA buffer. We sample the current buffer
// at a fixed FPS and pipe raw RGBA frames to ffmpeg for constant-rate output.
//
// Usage: node record.mjs [host:port] [out.mp4] [fps]

import zlib from "node:zlib";
import { spawn } from "node:child_process";
import { PNG } from "pngjs";

const HOST = process.argv[2] || "192.168.1.24:3000";
const OUT = process.argv[3] || "demo.mp4";
const FPS = Number(process.argv[4] || 10);

let width = 0;
let height = 0;
let buf = null; // RGBA framebuffer
let haveKeyframe = false;
let ffmpeg = null;
let ticker = null;
let frames = 0;

function startFfmpeg() {
  ffmpeg = spawn(
    "ffmpeg",
    [
      "-y",
      "-f", "rawvideo",
      "-pixel_format", "rgba",
      "-video_size", `${width}x${height}`,
      "-framerate", String(FPS),
      "-i", "-",
      "-vf", "format=yuv420p",
      "-movflags", "+faststart",
      OUT,
    ],
    { stdio: ["pipe", "inherit", "inherit"] }
  );
  ffmpeg.on("close", (code) => {
    console.log(`\nffmpeg exited ${code}; wrote ${frames} frames to ${OUT}`);
    process.exit(code ?? 0);
  });
  ticker = setInterval(() => {
    if (haveKeyframe && ffmpeg.stdin.writable) {
      ffmpeg.stdin.write(buf);
      frames++;
    }
  }, 1000 / FPS);
}

function applyDeltas(payload) {
  // payload: [4-byte uncompressed length][deflate-raw stream]
  const raw = zlib.inflateRawSync(payload.subarray(4));
  let cursor = 0;
  while (cursor < raw.length) {
    const offset = raw.readUInt32BE(cursor);
    const len = raw.readUInt32BE(cursor + 4);
    raw.copy(buf, offset, cursor + 8, cursor + 8 + len);
    cursor += len + 8;
  }
}

const ws = new WebSocket(`ws://${HOST}/ws`);
ws.binaryType = "arraybuffer";

ws.onopen = () => console.log(`connected to ws://${HOST}/ws — recording at ${FPS}fps, Ctrl-C to stop`);
ws.onclose = () => { console.log("stream disconnected"); stop(); };
ws.onerror = (e) => { console.error("ws error:", e.message || e); process.exit(1); };

ws.onmessage = (ev) => {
  const data = Buffer.from(ev.data);
  const type = data[0];
  if (type === 0) {
    width = data.readInt32BE(1);
    height = data.readInt32BE(5);
    buf = Buffer.alloc(width * height * 4);
    console.log(`dimensions: ${width}x${height}`);
    if (!ffmpeg) startFfmpeg();
  } else if (type === 1) {
    if (buf) applyDeltas(data.subarray(1));
  } else if (type === 2) {
    // pointer position — ignored for recording
  } else if (type === 3) {
    const png = PNG.sync.read(data.subarray(1));
    png.data.copy(buf);
    haveKeyframe = true;
  }
};

function stop() {
  if (ticker) clearInterval(ticker);
  if (ffmpeg && ffmpeg.stdin.writable) ffmpeg.stdin.end();
  else process.exit(0);
}

process.on("SIGINT", () => { console.log("\nstopping…"); stop(); });
