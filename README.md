# dsh-ops

Run the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh web`) from source on your own machine, and reach it from every network that
machine is attached to — LAN, VPN, mesh network, nothing special. No upstream
patch, no fork, and no dependency on any particular network.

Four things make that work:

* **The GUI binds `0.0.0.0`.** Upstream's CLI refuses `--host 0.0.0.0`, so the
  bind lives in the harness's own profile layer, where the Web runtime supports
  it: it trusts every non-internal IP address it answers on, so there is no
  address list to keep in step with the network.
* **`:3081` is a token-free bookmark.** A bare `GET` earns a redirect carrying
  the current launch token, so one bookmark survives every restart and update.
* **Settings work remotely.** The Models page, API keys and preferences need the
  client's privileged surface, which upstream grants to loopback pages only.
  `plugins/dsh-ops-operator-surface.mjs` extends it to the authorities you
  declare, from the harness's own plugin system — no client rebuild.
* **It keeps itself current.** A daily timer builds the newest release tag from
  source, smoke-tests it, and swaps only if it boots; a failure leaves the
  previous build running.

## Quickstart

```sh
git clone https://github.com/Fruffel/dsh-ops ~/Documents/dsh-ops
cd ~/Documents/dsh-ops
./install.sh            # node/pnpm check, units, profile layer, aliases, config
$EDITOR dsh-ops.conf    # only if you reach this host by NAME (see Configuration)
bin/dsh-sync.sh         # first build + deploy (minutes)
```

Then bookmark `http://<this-host>:3081/`. On a headless machine, confirm the whole
path from another machine on the network:

```sh
bin/dsh-check-gui.mjs http://<this-host>:3081/
```

`install.sh` and `bin/dsh-install-assets.sh` render the units from this checkout, so
the repo can live anywhere — the templates carry `@@OPS@@`, and the checkout's own
path is written into them.

## Layout

| Path | What |
| --- | --- |
| `harness/upstream` | Full git clone of `deepseek-ai/deepseek-harness` (never built here) |
| `harness/builds/<tag>` | One git worktree per built tag |
| `harness/current` | Symlink to the build the service runs |
| `harness/cordis.patch.web.yml` | Template for the `web` profile user layer (installed into `~/.dsh/profiles/web/`) |
| `plugins/dsh-ops-operator-surface.mjs` | The one DSH plugin this repo ships: remote pages get the operator surface |
| `dsh-ops.conf.example` | Template for the git-ignored `dsh-ops.conf` (ports, trusted names) |
| `bin/dsh-install-assets.sh` | Renders units + profile layer from this checkout (ownership-marker aware) |
| `bin/dsh-sync.sh` | Smart updater: newest tag on a channel → build → smoke test → swap, or keep last good |
| `bin/dsh-go.mjs` | Token-free entry: `:3081` → 302 to the current `?token=` URL |
| `bin/dsh-url.sh` | Prints the current `?token=` URLs for this host's addresses |
| `bin/dsh-check-gui.mjs` | Acceptance check: drives real Chrome through the app into Settings → Models |
| `systemd/` | User units: `dsh-web`, `dsh-go`, `dsh-update` (+ daily 03:00 timer) |
| `install.sh` / `uninstall.sh` | Bootstrap / remove a machine |

## Configuration

`install.sh` copies `dsh-ops.conf.example` to `dsh-ops.conf` on first run. That
file is git-ignored, so pulls and the daily updater never touch it, and
`bin/dsh-install-assets.sh` renders it into the units — every later run keeps
whatever it says.

| Setting | Default | Meaning |
| --- | --- | --- |
| `DSH_PORT` | `3080` | Port the GUI serves on |
| `DSH_GO_PORT` | `3081` | Port of the token-free bookmark entry |
| `DSH_TRUSTED_HOSTS` | empty | **Names** (not IPs) you reach this host by, space-separated |

By IP, everything already works: the harness trusts every non-internal address it
answers on. `DSH_TRUSTED_HOSTS` only has to name hostnames — DNS, MagicDNS, an
`/etc/hosts` alias, a reverse-proxy host. A name that is missing there answers
`403` on `/api`, and the Models page reports unavailable settings, so it is the
one setting most deployments want:

```sh
DSH_TRUSTED_HOSTS="dsh.example.com work-laptop.lan"
```

After editing: `bin/dsh-install-assets.sh && systemctl --user daemon-reload
&& systemctl --user restart dsh-web`.

## Design notes

### Everything binds 0.0.0.0

Upstream's CLI refuses `--host 0.0.0.0` ("binding all network interfaces is not
supported"), but the Web runtime underneath supports it: `resolveLanTrust`
samples every non-internal IPv4 literal once at boot, adds them to the `/api`
fence, and the startup line gains a `(LAN: ...)` address. dsh-ops declares that
bind in the profile layer instead of the flag, so:

* every address the host answers on works — LAN, VPN, loopback — with no list to
  keep in step;
* an address change needs no restart and no re-discovery;
* there is no forwarder process: the harness owns its port itself, so `Host`,
  `Origin`, cookies, `Sec-Fetch-*` and WebSockets arrive untouched.

`bin/dsh-go.mjs` on `:3081` binds the same way and redirects to whichever address
you used, so one bookmark habit works from anywhere. It is also the only endpoint
that hands out a session to whoever asks, so every attached network can reach the
GUI through it; `Environment=DSH_GO_HOST=<address>` in `dsh-go.service` narrows
that single entry, and leaves the GUI itself untouched.

### Reachability and identity are two different fences

* **Host/Origin fence** (`dsh-client-connection`, applied to every `/api`
  request): the `Host` must be loopback or match a `trustedHosts` entry, and an
  attached `Origin` must equal it. IP literals are trusted automatically;
  `DSH_TRUSTED_HOSTS` only adds the names you type. Upstream calls this a
  "custom non-loopback composition", supported by design.
* **Identity**: every RPC and WebSocket needs the signed browser cookie minted
  from the launch token. The `?token=` URL is needed **once** per authority;
  `cookieMaxAgeDays: 365` in the profile layer makes that cookie outlive
  restarts and updates.

Cookies are host-only and bound to hostname+port, so each address or name is its
own login. `dsh-go` (`:3081`) keeps a bookmark working across token rotations: it
reads the current token from the `dsh-web` journal and redirects you to the
authority you asked for.

### Why the Models page says "settings are unavailable in this browser"

The client grants its **privileged surface** only to a loopback page:

```ts
// packages/client/connection/src/client/index.ts
isLoopback: transport?.ownsHost === true || pageLocation === undefined
  || isLoopbackHostname(pageLocation.hostname)
// packages/client/ui-settings/src/client/index.ts
const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'
```

A page reached over the network is not loopback, so the settings mirror starts in
its terminal `unavailable` state and the Models page cannot render. Upstream does
this on purpose (`.agents/notes/implemented/bug-fix/2026-08-06-host-backed-web-preferences.md`:
"The Client keeps Host persistence disabled on non-loopback pages"), so it is a
policy a remote deployment has to answer, not a bug to paper over.

`plugins/dsh-ops-operator-surface.mjs` answers it inside the harness's own plugin
system:

* `webserver/index-inject` (dsh-host-webserver) is the documented seam for
  index-page bootstrap rows, collected on every served index request;
* `__DSH_TRANSPORT__` (dsh-client-connection, `ClientTransportHooks.ownsHost`) is
  the documented carrier hook a shell-owned page uses to declare that its page
  owns the Host — the same hook the Electron desktop and WebWorker shells set;
* the plugin reads the deployment's own authorities from the live
  `webRuntime.trustedHosts` service and injects a small head script that sets
  `ownsHost` for those authorities only. Loopback and unknown authorities are
  untouched.

It grants no reachability and no identity — the fence and the cookie still decide
both; anything that can load the page could already run shell commands through
it, so settings persistence is the smaller privilege. To go back to stock
behavior, delete the `insert` entry from `~/.dsh/profiles/web/cordis.patch.yml`
(the layer live-reloads). The zero-deviation alternative is to reach the GUI
through an SSH local forward and browse `http://localhost:<port>`, which upstream
documents for SSH sessions.

### The profile layer is a managed file

`~/.dsh/profiles/web/cordis.patch.yml` and the plugin beside it are installed by
`bin/dsh-install-assets.sh`. The patch carries a `dsh-ops:managed` marker: while
the marker is there dsh-ops refreshes it (keeping a `.bak`); delete the marker and
the file becomes yours and is never overwritten. `DSH_HOME` data otherwise
(sessions, credentials, settings) is untouched by syncs.

Three details the layer carries:

* A loader patch replaces the targeted row's **whole** config, so the
  `webserver` row restates every key it owns (with `host: '0.0.0.0'`) and the
  `connection` row restates `trustedHosts` with the bundle's own expression.
  Dropping that expression would silently fall back to `[]` and answer 403 to
  every remote request.
* The `modules` row gets `inject: [webServer]`. Its node half registers the
  `/plugins` route on the webserver and, when that service is already active,
  reads it through a bare `ctx.webServer` property access that only resolves when
  the service sits on the reading fiber. Without the declaration a boot fails
  with `cannot get property "webServer" without inject` — measured at 1 boot in 8
  here, otherwise self-healed only by `Restart=always`. Drop the row when
  upstream declares the injection itself.
* `bin/dsh-install-assets.sh` retires units this repo no longer ships (currently
  `dsh-proxy.service`, an earlier user-space forwarder), so a pulled checkout
  stays authoritative over what a machine has installed.

### Updates

`dsh-update.timer` runs `bin/dsh-sync.sh --channel rc` daily at 03:00
(`Persistent=true`, so a missed run happens on next boot). The sync looks for the
newest tag on the channel and only if there is one: refreshes units + profile
layer, creates a worktree, installs dependencies, builds, boots the result on an
OS-assigned port as a smoke test, swaps `harness/current`, and restarts the
services. Any failure leaves the previous build running.

Expect a short restart (~5-15 s) only when something actually changed; a session
running at that moment is interrupted, and the page reconnects. Channels:
`rc` (default, skips alpha), `stable` (plain `x.y.z` tags only), `latest`
(everything).

## Setup / uninstall

```sh
./install.sh
bin/dsh-sync.sh          # first build + deploy (takes minutes)
```

`install.sh` installs pnpm, writes `dsh-ops.conf`, renders the units, installs
the profile layer, enables `dsh-web`, `dsh-go` and the 03:00 timer, and writes
the shell aliases. Re-running it is safe.

Remove: `./uninstall.sh` stops/disables services, removes units and aliases and
keeps repo + data. `./uninstall.sh --purge` also removes the repo checkout,
harness builds and the profile layer (plugin and patch together — one without the
other leaves a row pointing at a missing module). Both support `--dry-run`.

## Usage

```sh
dsh-update                 # sync to newest rc tag, build, swap, restart
dsh-update --channel stable
dsh-update --ref dsh-v0.1.5-rc.2   # pin / roll back to a tag
dsh-update --dry-run       # show what would happen
dsh-url                    # current token URLs for this host's addresses
dsh-logs                   # follow dsh-web + dsh-go
bin/dsh-install-assets.sh --dry-run   # show unit/profile-layer drift
bin/dsh-check-gui.mjs http://<host>:3081/   # browser check: Models page renders
```

`bin/dsh-check-gui.mjs [entry-url]` drives headless Chrome from whatever machine
runs it, follows `dsh-go` into the app, opens Settings → Models and fails when the
panel says "settings are unavailable in this browser" again. It needs no packages
(CDP over Node's WebSocket) and resolves Chrome from `$CHROME` or the usual paths.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `403 forbidden` from `/api` | You reached the GUI on a **name** that is not in `DSH_TRUSTED_HOSTS`; IP literals are trusted automatically. Add it, re-run `bin/dsh-install-assets.sh`, restart `dsh-web` |
| `401 unauthorized` / login loop | You changed address and need the `?token=` URL once for that one — use `dsh-go` on `:3081` |
| "settings are unavailable in this browser" | The operator-surface plugin is not mounted, or the page's authority is outside `trustedHosts`. Check `systemctl --user status dsh-web` and `bin/dsh-install-assets.sh --dry-run` |
| "Add an API key to get started" on every load | No model provider can serve requests on that host yet. Paste your key once in the dialog (it is stored on the host), or export `DEEPSEEK_API_KEY` in the service environment |
| Nothing answers on the GUI port | `systemctl --user status dsh-web`; the bind lives in the profile layer, so also check `bin/dsh-install-assets.sh --dry-run` and `journalctl --user -u dsh-web -n 50` |
| `:3081` answers 503 | `dsh-go` reads the launch token from the `dsh-web` journal; if `dsh-web` has not printed its URL line yet, wait a moment and reload |
