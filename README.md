# dsh-ops

Small ops project that runs the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh web`) **from source** on `kamer-ts` and exposes it on the tailnet.

## Layout

| Path | What |
| --- | --- |
| `harness/upstream` | Full git clone of `deepseek-ai/deepseek-harness` (never built here) |
| `harness/builds/<tag>` | One git worktree per built tag |
| `harness/current` | Symlink to the build the service runs |
| `harness/cordis.patch.web.yml` | Template for the `web` profile user layer (installed into `~/.dsh/profiles/web/`) |
| `plugins/dsh-ops-operator-surface.mjs` | The one DSH plugin this repo ships: tailnet pages get the operator surface |
| `bin/dsh-install-assets.sh` | Renders units + profile layer from this checkout (ownership-marker aware) |
| `bin/dsh-sync.sh` | Smart updater: newest tag on a channel → build → smoke test → swap, or keep last good |
| `bin/dsh-go.mjs` | Token-free entry: tailnet `:3081` → 302 to the current `?token=` URL |
| `bin/dsh-url.sh` | Prints the current `?token=` URLs (local, tailnet IP, MagicDNS) |
| `proxy/tailscale-proxy.mjs` | User-space TCP forwarder: tailnet `:3080` → `127.0.0.1:3080` |
| `systemd/` | User units: `dsh-web`, `dsh-proxy`, `dsh-go`, `dsh-update` (+ daily 03:00 timer) |
| `install.sh` | Bootstrap a machine: node check, pnpm, units, profile layer, aliases |

The repo does not have to live at `~/Documents/dsh-ops`: `bin/dsh-install-assets.sh`
renders the checkout's own path into the unit templates (`@@OPS@@`).

## Design notes

### The harness never leaves loopback

Upstream refuses to bind all interfaces — `dsh web --host 0.0.0.0` exits with a
usage error, and the package README ends with "Binding all network interfaces is
not supported — use the default loopback host". So `dsh-web` runs exactly as
shipped (`--host 127.0.0.1`, no `webserver` row in the profile layer), and the
tailnet listener is `dsh-proxy`: a raw TCP forwarder bound to the machine's
tailnet address only. Raw TCP is what makes this cheap — `Host`, `Origin`,
cookies, `Sec-Fetch-*` and WebSockets all cross untouched, so the harness still
sees the authority the browser typed. Nothing else on the machine (LAN, docker
bridges) is exposed.

### Reachability and identity are two different fences

* **Host/Origin fence** (`dsh-client-connection`, applied to every `/api`
  request): the `Host` must be loopback or match a `trustedHosts` entry, and an
  attached `Origin` must equal it. `--trusted-host` in `dsh-web.service` is the
  single place the tailnet authorities are declared; upstream calls this a
  "custom non-loopback composition", which is supported by design.
* **Identity**: every RPC and WebSocket needs the signed browser cookie minted
  from the launch token. The `?token=` URL is needed **once** per authority;
  `cookieMaxAgeDays: 365` in the profile layer makes that cookie outlive
  restarts and updates.

Cookies are host-only and bound to hostname+port, so `kamer`, `kamer.tail39c8ca.ts.net`
and `100.93.30.88` are three separate logins. `dsh-go` (:3081) keeps a bookmark
working across token rotations: it reads the current token from the `dsh-web`
journal and redirects to the authority you asked for.

### Why the Models page used to say "settings are unavailable in this browser"

The client grants its **privileged surface** only to a loopback page:

```ts
// packages/client/connection/src/client/index.ts
isLoopback: transport?.ownsHost === true || pageLocation === undefined
  || isLoopbackHostname(pageLocation.hostname)
// packages/client/ui-settings/src/client/index.ts
const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'
```

A page on `kamer:3080` is not loopback, so the settings mirror starts in its
terminal `unavailable` state and the Models page renders
"Loading the provider directory failed: settings are unavailable in this
browser" — however well the browser authenticated. Upstream does this on purpose
(`.agents/notes/implemented/bug-fix/2026-08-06-host-backed-web-preferences.md`:
"The Client keeps Host persistence disabled on non-loopback pages"), so it is not
a deployment bug to paper over: it is a policy the tailnet deployment has to
answer.

`plugins/dsh-ops-operator-surface.mjs` answers it inside the harness's own
plugin system, without patching upstream or rebuilding client bundles:

* `webserver/index-inject` (dsh-host-webserver) is the documented seam for
  index-page bootstrap rows, collected on every served index request.
* `__DSH_TRANSPORT__` (dsh-client-connection, `ClientTransportHooks.ownsHost`) is
  the documented carrier hook a shell-owned page uses to declare that its page
  owns the Host — the same hook the Electron desktop and WebWorker shells set.
* The plugin reads the deployment's own authorities from the live
  `webRuntime.trustedHosts` service (i.e. exactly the `--trusted-host` list the
  fence already trusts) and injects a small head script that sets `ownsHost` for
  those authorities only. Loopback and unknown authorities are untouched.

It grants no reachability and no identity — the fence and the cookie still decide
both; an authority that can load the page could already run shell commands
through it, so settings persistence is the smaller privilege. To go back to
stock behavior, delete the `insert` entry from
`~/.dsh/profiles/web/cordis.patch.yml` (the layer live-reloads) and every page
is loopback-only again. The zero-deviation alternative is to reach the GUI
through an SSH local forward and browse `http://localhost:3080`, which upstream
documents for SSH sessions.

### The profile layer is a managed file

`~/.dsh/profiles/web/cordis.patch.yml` and the plugin beside it are installed by
`bin/dsh-install-assets.sh`. The patch carries a `dsh-ops:managed` marker:
while the marker is there dsh-ops refreshes it (keeping a `.bak`); delete the
marker and the file becomes yours and is never overwritten. `DSH_HOME` data
otherwise (sessions, credentials, settings) is untouched by syncs.

Two details the layer carries beyond the plugin:

* A loader patch replaces the targeted row's **whole** config, so the
  `connection` row restates `trustedHosts` with the bundle's own expression
  (`!!js ctx.webRuntime.trustedHosts`). Dropping that line would silently fall
  back to `[]` and answer 403 to every tailnet request.
* The `modules` row gets `inject: [webServer]`. Its node half registers the
  `/plugins` route on the webserver and, when that service is already active,
  reads it through a bare `ctx.webServer` property access that only resolves
  when the service sits on the reading fiber. Without the declaration a boot
  fails with `cannot get property "webServer" without inject` — measured at
  1 boot in 8 here, and only ever self-healed by `Restart=always`. Drop the row
  when upstream declares the injection itself.

## Setup / uninstall

Fresh machine:

```sh
./install.sh
bin/dsh-sync.sh          # first build + deploy (takes minutes)
```

`install.sh` installs pnpm, renders the units, installs the profile layer,
enables `dsh-web`, `dsh-proxy`, `dsh-go` and the 03:00 timer, and writes the
shell aliases. Re-running it is safe.

Remove: `./uninstall.sh` stops/disables services, removes units and aliases and
keeps repo + data. `./uninstall.sh --purge` also removes the repo checkout,
harness builds and the profile layer (plugin and patch together — one without
the other leaves a row pointing at a missing module). Both support `--dry-run`.

## Connect

Bookmark `http://kamer:3081/` (or `http://100.93.30.88:3081/`). `dsh-go` redirects
to the current `?token=` URL for the authority you used, which mints the cookie.
The token rotates on every restart/update; the bookmark keeps working.

## Usage

```sh
dsh-update                 # sync to newest rc tag, build, swap, restart
dsh-update --channel stable
dsh-update --ref dsh-v0.1.5-rc.2   # pin / roll back to a tag
dsh-update --dry-run       # show what would happen
dsh-url                    # current token URLs
dsh-logs                   # follow dsh-web + dsh-proxy
bin/dsh-install-assets.sh --dry-run   # show unit/profile-layer drift
```

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `403 forbidden` from `/api` | The authority you typed is not in `--trusted-host` (`dsh-web.service`); add it and rerun `bin/dsh-install-assets.sh` + `systemctl --user restart dsh-web` |
| `401 unauthorized` / login loop | You changed authority (host/port) and need the `?token=` URL once for that one — use `dsh-go` on `:3081` |
| "settings are unavailable in this browser" | The operator-surface plugin is not mounted, or you reached the page on an authority outside `--trusted-host`. Check `systemctl --user status dsh-web` and `bin/dsh-install-assets.sh --dry-run` |
| Tailnet `:3080` refuses connections | `dsh-proxy` is down or DSH took the socket: `systemctl --user status dsh-proxy dsh-web` (the proxy retries every 5s) |
