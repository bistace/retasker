# tools

Dev tooling for reTasker. Not part of the shipped app.

## record-stream.mjs

Records an [appload-rmstream](https://github.com/asivery/appload-rmstream) feed
to an mp4 — for demo videos. It connects to the stream's `/ws` WebSocket,
reconstructs each frame (keyframe PNG + `deflate-raw` deltas) the same way the
browser client does, and samples at a fixed FPS so the output is constant-rate
regardless of how bursty the e-ink updates are.

### Requirements

- Node 22+ (uses the built-in `WebSocket`)
- `ffmpeg` on `PATH`
- `npm install` in this directory (pulls `pngjs` for keyframe decoding)
- `rmstream` running on the tablet (`vellum add rmstream`)

### Usage

```bash
npm install
node record-stream.mjs [host:port] [out.mp4] [fps]
# e.g.
node record-stream.mjs 192.168.1.24:3000 demo.mp4 10
```

Drive the demo on the tablet, then Ctrl-C to stop; ffmpeg finalizes the file.
Hit **Disable Cursor** in the stream page's hamburger menu first to keep the
pointer overlay out of the recording.

### Polishing for a README video

```bash
# scale down + 2x speed-up, web-optimized mp4
ffmpeg -i demo.mp4 -vf "setpts=0.5*PTS,scale=600:-1:flags=lanczos" -an -movflags +faststart demo-web.mp4
```

Drag the mp4 into a GitHub README/PR/issue — GitHub renders it inline.
