import http from "node:http";
import { execFileSync } from "node:child_process";

// Token-free entry point: GET http://<any-address>:3081/ -> 302 to the current
// dsh "?token=" URL (the token rotates on every restart; this always reads the
// latest one from the dsh-web journal). Visiting it mints the browser cookie,
// exactly as opening the token URL by hand would.
//
// It listens on every interface by default, like the harness itself: the
// address you asked for is the address you get redirected to, so no host list
// and no network discovery is involved. Narrow it with DSH_GO_HOST (or argv[2])
// if you ever want this entry restricted to one interface -- it is the one
// endpoint that hands out a session to whoever asks.

const PORT = Number(process.env.DSH_GO_PORT || 3081);
const DSH_PORT = Number(process.env.DSH_TARGET_PORT || 3080);
const LISTEN_HOST = process.argv[2] || process.env.DSH_GO_HOST || "0.0.0.0";

// The startup line is "dsh web: http://127.0.0.1:<port>/?token=..." plus an
// optional "(LAN: http://<addr>:<port>/?token=...)" suffix; both carry the same
// process token, so match the token on any host and take the newest line.
const TOKEN_PATTERN = new RegExp("http://[^\\s]*:" + DSH_PORT + "/\\?token=([A-Za-z0-9_-]+)", "g");

function currentToken() {
  try {
    const out = execFileSync(
      "journalctl",
      ["--user", "-u", "dsh-web.service", "-n", "200", "--no-pager"],
      { encoding: "utf8" },
    );
    const hits = out.match(TOKEN_PATTERN);
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
  // Redirect to the authority the browser used, so the cookie it receives is
  // bound to the address it will keep talking to.
  const host = String(req.headers.host || "").split(":")[0] || "127.0.0.1";
  res.writeHead(302, {
    location: "http://" + host + ":" + DSH_PORT + "/?token=" + token,
    "cache-control": "no-store",
  });
  res.end();
});

server.on("error", (err) => {
  console.error("dsh-go: listen " + LISTEN_HOST + ":" + PORT + " failed: " + err.message);
  process.exit(1);
});

server.listen(PORT, LISTEN_HOST, () => {
  console.log("dsh-go: http://" + LISTEN_HOST + ":" + PORT + "/ -> dsh token login (port " + DSH_PORT + ")");
});
