import net from "node:net";
import { execSync } from "node:child_process";

// Forwards Tailnet -> localhost so DSH (localhost-only by design) is
// reachable via Tailscale without ever binding 0.0.0.0.
// Raw TCP forward: preserves Host header + WebSockets transparently.

function tailscaleIp() {
  try {
    const out = execSync("tailscale ip -4", { encoding: "utf8" });
    const ip = out.split("\n").map((s) => s.trim()).find(Boolean);
    if (ip) return ip;
  } catch {}
  return undefined;
}

const listenHost = process.argv[2] || process.env.DSH_LISTEN_HOST || tailscaleIp();
const listenPort = Number(process.argv[3] || process.env.DSH_LISTEN_PORT || 3080);
const targetHost = process.env.DSH_TARGET_HOST || "127.0.0.1";
const targetPort = Number(process.env.DSH_TARGET_PORT || 3080);

if (!listenHost) {
  console.error("tailscale-proxy: could not determine Tailscale IPv4 (is tailscaled running?)");
  process.exit(1);
}

const server = net.createServer((client) => {
  const backend = net.connect(targetPort, targetHost);
  const close = () => {
    client.destroy();
    backend.destroy();
  };
  client.on("error", close);
  backend.on("error", close);
  client.pipe(backend);
  backend.pipe(client);
});

server.on("error", (err) => {
  console.error(`tailscale-proxy: listen ${listenHost}:${listenPort} failed: ${err.message}`);
  process.exit(1);
});

server.listen(listenPort, listenHost, () => {
  console.log(`tailscale-proxy: ${listenHost}:${listenPort} -> ${targetHost}:${targetPort}`);
});
