# dsh-ops

Run the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh web`) from source on your own machine, and open it from anywhere that
machine is reachable — same LAN, VPN, mesh network. One bookmark, no token
juggling, settings and the Models page work remotely, and it updates itself.

## Quickstart

```sh
git clone https://github.com/Fruffel/dsh-ops
cd dsh-ops
./install.sh          # pnpm, services, timer, profile layer, config
./bin/dsh-sync.sh     # first build + deploy (minutes)
```

The checkout can live anywhere — `install.sh` renders its own path into the
units. Nothing is installed into your shell: it is just a service.

Then bookmark `http://<this-host>:3081/`. That is it.

Reach it by IP out of the box. If you also want to reach it by **name** (DNS,
MagicDNS, `/etc/hosts`), put that name in `dsh-ops.conf` and re-run `./install.sh`:

```sh
DSH_TRUSTED_HOSTS="dsh.example.com work-laptop.lan"
```

## How it works

* The GUI listens on every interface (`0.0.0.0`), so whatever address you have
  works — no address list, no forwarder, no network-specific setup.
* `:3081` watches the harness for its current login token and redirects you
  through it, so the bookmark keeps working across restarts and updates.
* Settings, API keys and the Models page work from remote pages too, via one
  small plugin (`plugins/dsh-ops-operator-surface/`) that extends the client's
  privileged surface to the authorities you declared.
* Plugins are installed, not committed: `plugins.conf` names plugin
  repositories, `bin/dsh-plugins.sh` checks them out into a git-ignored
  `plugins/`, and the profile layer mounts whatever is there. The harness itself
  works the same way (`harness/upstream`, `harness/builds`).
* One of those plugins (`dsh-ops-updater`) adds **Settings → Updates**: what is
  installed, a *Check for updates* button that asks the channel for its newest
  tag, one that builds and installs it, and a **Plugins** card that checks and
  updates the plugin checkouts. The build, the smoke test and the swap are the
  same script the command line runs — a failure leaves the previous build
  running.
* Updates happen when you ask for them. A nightly timer is available
  (`DSH_AUTO_UPDATE=1` in `dsh-ops.conf`, or the switch on that page) but off by
  default.
* Upstream is untouched: everything lives in your profile layer and this repo.

## Updates

Open the GUI, go to **Settings → Updates**. The page shows the release you are
running, the channel it follows, and — after one click — whether the channel has
something newer. *Install* then runs the whole pipeline in the background:

The page itself is a plugin, kept in
[its own repository](https://github.com/Fruffel/dsh-ops-updater) because it is
the page, not the pipeline:

```sh
git clone https://github.com/Fruffel/dsh-ops-updater plugins/dsh-ops-updater
npm run assets                   # copies the package into the profile layer
systemctl --user restart dsh-web # its row mounts at boot
```


1. `dsh-sync.sh` fetches the newest tag on the channel (`rc` by default),
2. installs dependencies and builds it in its own worktree,
3. boots it once on an OS-assigned port as a smoke test,
4. only then swaps `harness/current` and restarts the services.

The page follows the run (phase, message, log) and the harness reconnects on its
own when it comes back. A failure at any step keeps the running build exactly as
it was.

### Plugins

Plugins are repositories too, so they get the same treatment one level down:

```sh
./bin/dsh-plugins.sh --install   # clone what plugins.conf declares (no updates)
./bin/dsh-plugins.sh --check     # is any checkout behind its remote?
./bin/dsh-plugins.sh --update    # fast-forward, refresh the layer, restart
./bin/dsh-plugins.sh --list      # the manifest as this machine resolves it
```

One machine-local manifest, `plugins.conf` — one repository or local path per
line, optionally pinned to a ref — seeded by `install.sh` from the tracked
`plugins.conf.example`, the same pattern as `dsh-ops.conf`. The template's one
non-negotiable entry is the updater: that is what gives a fresh clone a way to
install anything else from the GUI.

It is machine-local so that neither plugin code nor the set of plugins a
particular deployment runs is ever part of this repository. Every entry clones
into the git-ignored `plugins/`.

A checkout with local changes is reported and left alone, an entry whose
checkout has no `origin` is reported as unmanaged, and a run that changes
nothing restarts nothing.

Both update paths deliberately run as their own systemd unit
(`dsh-update.service`, `dsh-plugins.service`) rather than as a child of the web
server: each ends by restarting that server, and a child in the same cgroup
would be killed by the restart it is performing.

Anything the page can do is also a command:

```sh
./bin/dsh-sync.sh --check          # is there something newer? (builds nothing)
./bin/dsh-sync.sh --check --json   # the same, machine-readable
./bin/dsh-sync.sh                  # update now
./bin/dsh-sync.sh --channel stable # follow plain x.y.z tags instead of rc
```

## Commands

Run these from the checkout. `npm run <name>` and `./bin/<script>` are the same
thing — the npm scripts are just short names (pnpm works too).

| npm run | Direct | What |
| --- | --- | --- |
| `update` | `./bin/dsh-sync.sh` | Update the harness now (newest tag → build → smoke test → swap). Add `-- --check` to only report, `-- --dry-run`, `-- --channel stable`, `-- --ref <tag>` to pin |
| `plugins` | `./bin/dsh-plugins.sh` | Plugins: `--install` (clone what the manifest declares), `--check`, `--update`, `--list` |
| `url` | `./bin/dsh-url.sh` | Print the current login URLs for this host |
| `logs` | `./bin/dsh-logs.sh` | Follow the services |
| `check` | `./bin/dsh-check-gui.mjs` | Browser check: `npm run check -- http://<host>:3081/` |
| `assets` | `./bin/dsh-install-assets.sh` | Re-render units + profile layer from this checkout and `dsh-ops.conf` |
| `bootstrap` | `./install.sh` | Re-run the machine setup |
| `uninstall` | `./uninstall.sh` | Remove the service (keeps data); `-- --purge` removes the checkout too |

Updates are on demand: the GUI page, or the commands above. `DSH_AUTO_UPDATE=1`
in `dsh-ops.conf` also enables `dsh-update.timer` (daily 03:00) for a machine
that should look after itself.

## Configuration

`dsh-ops.conf` is this deployment's own settings (created by `install.sh`,
git-ignored):

| Setting | Default | Meaning |
| --- | --- | --- |
| `DSH_PORT` | `3080` | Port the GUI serves on |
| `DSH_GO_PORT` | `3081` | Port of the token-free entry |
| `DSH_TRUSTED_HOSTS` | empty | Names you reach this host by, space-separated |
| `DSH_UPDATE_CHANNEL` | `rc` | Which releases to follow: `rc` (newest tag, alpha excluded), `stable` (plain `x.y.z`), `latest` (everything) |
| `DSH_AUTO_UPDATE` | `0` | `1` runs `dsh-update.timer` daily at 03:00; `0` updates only when asked |

`plugins.conf` (machine-local, git-ignored) is the plugin manifest and carries
no settings. A plugin is mounted by a generated row, so anything a deployment
wants to pin — a `baseURL`, an extra authority — belongs in
`harness/cordis.patch.local.yml` (also git-ignored), which is appended after the
generated rows and patches a row by id:

```yaml
- id: dsh-llm-llamacpp
  config:
    baseURL: http://desktop:8080/v1
```

## If something is off

| Symptom | Fix |
| --- | --- |
| GUI loads, settings say "unavailable in this browser" | The page's hostname is missing from `DSH_TRUSTED_HOSTS` |
| `403` on `/api` | Same thing — IPs are trusted automatically, names are not |
| Login loop / `401` | You switched address; open `http://<that-address>:3081/` once to get a cookie for it |
| "Add an API key to get started" | Normal first-run step: paste your DeepSeek key once, or set `DEEPSEEK_API_KEY` for the service |
| Nothing on `:3081` yet | It reads the token from the harness journal — give it a few seconds after a restart |
| Turn fails with `REQUEST_EXTENSION` | The operator-surface plugin must be a versioned package; re-run `npm run assets` and restart `dsh-web` |
| No **Updates** page under Settings | The plugin row mounts at boot, not on install: `systemctl --user restart dsh-web` once, then reload the page |
| A plugin is missing from the GUI | `./bin/dsh-plugins.sh --install` clones what `plugins.conf` declares, then re-run `npm run assets` |
| No `plugins.conf` on a fresh clone | `install.sh` writes it from `plugins.conf.example`; running only `npm run assets` installs nothing but this repo's own `layer/` packages |
| A plugin update pulled but nothing changed | It refreshed the layer and restarted; `harness/state/plugins.log` has the detail. A run that changes nothing restarts nothing |
| Updates page says the checkout was not found | Start the harness some other way? Name it on the row: `config: { opsPath: /path/to/dsh-ops }` in `~/.dsh/profiles/web/cordis.patch.yml`, then restart |
| Update went wrong | The page shows the failure and the log; nothing was swapped. `npm run update -- --check`, then `npm run update -- --ref <previous-tag>`; the last good build kept running |

## Files

| Path | What |
| --- | --- |
| `install.sh` / `uninstall.sh` | Bootstrap / remove a machine |
| `bin/dsh-sync.sh` | The harness updater (`--check` to report, otherwise build → smoke test → swap, or keep last good) |
| `bin/dsh-go.mjs` / `bin/dsh-url.sh` | The `:3081` entry / the URL helper |
| `bin/dsh-check-gui.mjs` | Browser acceptance check |
| `plugins.conf` / `.example` | This machine's plugin repositories (git-ignored, created by `install.sh`); the template names the bootstrap updater |
| `plugins/` | Git-ignored: the plugin checkouts themselves, cloned from the manifest |
| `layer/` | This repo's own plugin packages, always installed because every deployment needs them (`dsh-ops-operator-surface`) |
| `bin/dsh-plugins.sh` | The plugin installer/updater: install, check, update, list |
| `harness/cordis.patch.web.yml` | The rows this repo always applies; the plugin rows are generated from what is installed, and `harness/cordis.patch.local.yml` (git-ignored) patches them per deployment |
| `harness/state/` | Machine-local: the running (or last) update's progress record and log |
| `systemd/` | `dsh-web`, `dsh-go`, `dsh-update` + its optional daily timer, and `dsh-plugins` |
| `dsh-ops.conf.example` | Config template |

The longer reasoning — why `0.0.0.0` needs a profile-layer patch, what the two
trust fences are, why the Models page needs that plugin, and why an update runs
as its own systemd unit — is in [DESIGN.md](DESIGN.md).
