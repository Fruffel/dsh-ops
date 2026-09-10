import http from "node:http";
import { execSync, execFileSync } from "node:child_process";

// Token-free entry point: GET http://<tail-host>:3081/ -> 302 to the current
// dsh `?token=` URL (token rotates every restart; this always reads the latest
// one from the dsh-web logs). Visiting it mints the browser cookie, same as
// opening the token URL by hand.

const PORT = Number(process.env.DSH_GO_PORT || 3081);
const DSH_PORT = Number(process.env.DSH_TARGET_PORT || 3080);

function tailscaleIp() {
  try {
    const out = execSync("tailscale ip -4", { encoding: "utf8" });
    const ip = out.split("\n").map((s) => s.trim()).find(Boolean);
    if (ip) return ip;
  } catch {}
  return undefined;
}

const LISTEN_HOST = process.argv[2] || process.env.DSH_GO_HOST || tailscaleIp();
if (!LISTEN_HOST) {
  console.error("dsh-go: could not determine Tailscale IPv4 (is tailscaled running?)");
  process.exit(1);
}

function currentToken() {
  try {
    const out = execFileSync(
      "journalctl",
      ["--user", "-u", "dsh-web.service", "-n", "100", "--no-pager"],
      { encoding: "utf8" },
    );
    const hits = out.match(/http:\/\/127\.0\.0\.1:3080\/\?token=([A-Za-z0-9_-]+)/g);
    if (!hits || hits.length === 0) return undefined;
    return hits[hits.length - 1].split("token=")[1];
  } catch {
    return undefined;
  }
}

const server = http.createServer((req, res) => {
  const token = currentToken();
  if (!token) {
    res.writeHead(503, { "content-type": "text/plain; charset=utf-8" });
    res.end("dsh-go: no startup token in dsh-web logs yet; is dsh-web running?\n");
    return;
  }
  const host = String(req.headers.host || "").split(":")[0] || LISTEN_HOST;
  res.writeHead(302, {
    location: `http://${host}:${DSH_PORT}/?token=${token}`,
    "cache-control": "no-store",
  });
  res.end();
});

server.on("error", (err) => {
  console.error(`dsh-go: listen ${LISTEN_HOST}:${PORT} failed: ${err.message}`);
  process.exit(1);
});

server.listen(PORT, LISTEN_HOST, () => {
  console.log(`dsh-go: http://${LISTEN_HOST}:${PORT}/ -> dsh token login (port ${DSH_PORT})`);
});
