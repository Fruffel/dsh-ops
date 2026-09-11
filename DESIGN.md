# dsh-ops design notes

The reasoning behind the pieces that are not obvious. The [README](README.md) is
the short version; this file is for whoever needs to change them.

## Everything binds 0.0.0.0

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

## Reachability and identity are two different fences

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

A name that is not in `DSH_TRUSTED_HOSTS` fails that fence with `403` on `/api`,
which surfaces in the GUI as unavailable settings.

## Why the Models page needs the operator-surface plugin

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

`plugins/dsh-ops-operator-surface/` answers it inside the harness's own plugin
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

## The profile layer is a managed file

`~/.dsh/profiles/web/cordis.patch.yml` and the plugin package beside it are
installed by `bin/dsh-install-assets.sh`. The patch carries a `dsh-ops:managed`
marker: while the marker is there dsh-ops refreshes it (keeping a `.bak`); delete
the marker and the file becomes yours and is never overwritten. `DSH_HOME` data
otherwise (sessions, credentials, settings) is untouched by syncs.

Four details the layer carries:

* A loader patch replaces the targeted row's **whole** config, so the
  `webserver` row restates every key it owns (with `host: '0.0.0.0'`) and the
  `connection` row restates `trustedHosts` with the bundle's own expression.
  Dropping that expression would silently fall back to `[]` and answer 403 to
  every remote request.
* The `modules` row gets `inject: [webServer]`. Its node half registers the
  `/plugins` route on the webserver and, when that service is already active,
  reads it through a bare `ctx.webServer` property access that only resolves when
  the service sits on the reading fiber. Without the declaration a boot fails
  with `cannot get property "webServer" without inject` — measured at 1 boot in 8,
  otherwise self-healed only by `Restart=always`. Drop the row when upstream
  declares the injection itself.
* `bin/dsh-install-assets.sh` retires units this repo no longer ships (currently
  `dsh-proxy.service`, an earlier user-space forwarder), so a pulled checkout
  stays authoritative over what a machine has installed.
* The operator-surface plugin is a versioned package
  (`plugins/dsh-ops-operator-surface/`, name + version) rather than a loose file
  next to the profile's `package.json`. Official DeepSeek requests inventory
  every active Loader plugin (`dsh_plugin_packages`); a relative module whose
  nearest named manifest has no version fails the request with
  `REQUEST_EXTENSION`. The profile's own `package.json` is named
  `dsh-profile-web` and has no version, so a loose `./plugin.mjs` beside it
  poisons every run.

## Updates

Releases are installed on request, from **Settings → Updates** in the GUI, and
that page is a thin skin over the same script a terminal runs.

`bin/dsh-sync.sh` has two modes. `--check` fetches the tags, resolves the newest
one on the channel, compares it with `harness/current-ref`, and reports — it
builds nothing and restarts nothing; `--check --json` is the same answer for the
plugin. Its default mode resolves, refreshes units + the profile layer, creates a
worktree, installs dependencies, builds, boots the result on an OS-assigned port
as a smoke test, and only then swaps `harness/current` and restarts the services.
Any failure leaves the previous build running. The channel comes from
`DSH_UPDATE_CHANNEL` in `dsh-ops.conf`, so the page, the timer and a terminal
cannot disagree about which channel this machine follows.

Every run writes `harness/state/update.json` (state, phase, message, target,
timestamps) and appends to `harness/state/update.log`. The page polls both while
a run is in flight, which is what makes progress visible — and it works the same
for a run started by the timer or by hand, because the script is the only writer.

**Why an update is a systemd unit.** It ends by restarting `dsh-web` — the very
process the plugin runs in. A child of that process sits in the same cgroup, and
systemd's default `KillMode=control-group` kills the whole group on restart, so
an update started from inside the harness would die at the moment it needs to
finish. `dsh-update.service` exists for that: the plugin asks systemd to run it
in its own cgroup (`systemctl --user start --no-block dsh-update.service`) and
the process outlives the restart it performs. A detached spawn is only the
fallback for a harness that is not running under systemd at all, and the page
says so when it happens.

The daily timer (`dsh-update.timer`, 03:00, `Persistent=true`) is opt-in:
`DSH_AUTO_UPDATE=1` in `dsh-ops.conf`, which the page's switch writes.
`dsh-install-assets.sh` applies that value on every run, so the choice survives
later updates instead of being silently reverted. The unit itself is always
installed and startable; only the timer is enabled or disabled.

**The page is a plugin of its own** (`dsh-ops-updater`, cloned into `plugins/`;
this repo carries only its row in the patch and warns when the package is
missing). Its Host half reaches the browser through ONE exact `/api` route,
which is dispatched by the same code as `/api` — so the Host/Origin fence and
the signed browser cookie are applied before the handler runs, which a bare
`ctx.webServer` route would not have. The plugin's own README carries the rest:
endpoints, discovery, tests.

**Live reload is not relied on.** A profile with `patchReload: live` is supposed
to reapply `cordis.patch.yml` on edit; on this deployment that was not observed
— a replaced patch file produced no reload and no diagnostic — so a row added by
a pull takes effect on the next `dsh-web` restart. `dsh-sync.sh` restarts the
services when the assets it installs changed, which is why installing the updater
works: the page appears after that restart, not before.

Expect a short restart (~5-15 s) when something actually changed; a session
running at that moment is interrupted, and the page reconnects. Channels: `rc`
(default, skips alpha), `stable` (plain `x.y.z` tags only), `latest`
(everything).
