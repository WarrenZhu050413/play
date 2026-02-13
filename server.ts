#!/usr/bin/env bun
import { resolve, basename, extname } from "path";

const MIME: Record<string, string> = {
  ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".wav": "audio/wav",
  ".ogg": "audio/ogg", ".flac": "audio/flac", ".aac": "audio/aac",
  ".wma": "audio/x-ms-wma", ".opus": "audio/opus", ".webm": "audio/webm",
  ".mp4": "video/mp4", ".mkv": "video/x-matroska", ".mov": "video/quicktime",
};

const args = process.argv.slice(2);
let filePath = "";
let speed = 1.0;
let port = 9876;

for (let i = 0; i < args.length; i++) {
  if ((args[i] === "-s" || args[i] === "--speed") && args[i + 1]) {
    speed = parseFloat(args[++i]);
  } else if ((args[i] === "-p" || args[i] === "--port") && args[i + 1]) {
    port = parseInt(args[++i]);
  } else if (!args[i].startsWith("-")) {
    filePath = resolve(args[i]);
  }
}

if (!filePath) {
  console.error("Usage: play <file> [-s speed] [-p port]");
  process.exit(1);
}

const file = Bun.file(filePath);
if (!await file.exists()) {
  console.error(`File not found: ${filePath}`);
  process.exit(1);
}

const fileName = basename(filePath);
const ext = extname(filePath).toLowerCase();
const mime = MIME[ext] || "application/octet-stream";
const playerHtml = await Bun.file(resolve(import.meta.dir, "player.html")).text();

// Inject config into HTML
const injectedHtml = playerHtml.replace(
  "/*__CONFIG__*/",
  `window.__CONFIG__ = { fileName: ${JSON.stringify(fileName)}, speed: ${speed}, audioUrl: "/audio" };`
);

const server = Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/") {
      return new Response(injectedHtml, { headers: { "Content-Type": "text/html; charset=utf-8" } });
    }

    if (url.pathname === "/audio") {
      const f = Bun.file(filePath);
      const size = f.size;
      const range = req.headers.get("range");

      if (range) {
        const match = range.match(/bytes=(\d+)-(\d*)/);
        if (match) {
          const start = parseInt(match[1]);
          const end = match[2] ? parseInt(match[2]) : size - 1;
          return new Response(f.slice(start, end + 1), {
            status: 206,
            headers: {
              "Content-Type": mime,
              "Content-Range": `bytes ${start}-${end}/${size}`,
              "Content-Length": String(end - start + 1),
              "Accept-Ranges": "bytes",
            },
          });
        }
      }

      return new Response(f, {
        headers: { "Content-Type": mime, "Content-Length": String(size), "Accept-Ranges": "bytes" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`\x1b[33m▶ play\x1b[0m ${fileName} @ ${speed}x`);
console.log(`  http://localhost:${server.port}`);
console.log(`  \x1b[2mCtrl+C to stop\x1b[0m`);

// Open browser
Bun.spawn(["open", `http://localhost:${server.port}`]);

// Graceful shutdown
process.on("SIGINT", () => {
  server.stop();
  process.exit(0);
});
