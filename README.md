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
  small plugin (`plugins/dsh-ops-operator-surface.mjs`) that extends the client's
  privileged surface to the authorities you declared.
* A daily timer builds the newest release tag from source, smoke-tests it, and
  swaps only if it boots — a failure leaves the previous build running.
* Upstream is untouched: everything lives in your profile layer and this repo.

## Commands

Run these from the checkout. `npm run <name>` and `./bin/<script>` are the same
thing — the npm scripts are just short names (pnpm works too).

| npm run | Direct | What |
| --- | --- | --- |
| `update` | `./bin/dsh-sync.sh` | Update now (newest tag → build → smoke test → swap). Add `-- --dry-run`, `-- --channel stable`, `-- --ref <tag>` to pin |
| `url` | `./bin/dsh-url.sh` | Print the current login URLs for this host |
| `logs` | `./bin/dsh-logs.sh` | Follow the services |
| `check` | `./bin/dsh-check-gui.mjs` | Browser check: `npm run check -- http://<host>:3081/` |
| `assets` | `./bin/dsh-install-assets.sh` | Re-render units + profile layer from this checkout and `dsh-ops.conf` |
| `bootstrap` | `./install.sh` | Re-run the machine setup |
| `uninstall` | `./uninstall.sh` | Remove the service (keeps data); `-- --purge` removes the checkout too |

The daily update runs on its own (`dsh-update.timer`, 03:00), so this is only
for doing it by hand.

## Configuration

`dsh-ops.conf` (created by `install.sh`, git-ignored):

| Setting | Default | Meaning |
| --- | --- | --- |
| `DSH_PORT` | `3080` | Port the GUI serves on |
| `DSH_GO_PORT` | `3081` | Port of the token-free entry |
| `DSH_TRUSTED_HOSTS` | empty | Names you reach this host by, space-separated |

## If something is off

| Symptom | Fix |
| --- | --- |
| GUI loads, settings say "unavailable in this browser" | The page's hostname is missing from `DSH_TRUSTED_HOSTS` |
| `403` on `/api` | Same thing — IPs are trusted automatically, names are not |
| Login loop / `401` | You switched address; open `http://<that-address>:3081/` once to get a cookie for it |
| "Add an API key to get started" | Normal first-run step: paste your DeepSeek key once, or set `DEEPSEEK_API_KEY` for the service |
| Nothing on `:3081` yet | It reads the token from the harness journal — give it a few seconds after a restart |
| Update went wrong | `npm run update -- --dry-run`, then `npm run update -- --ref <previous-tag>`; the last good build kept running |

## Files

| Path | What |
| --- | --- |
| `install.sh` / `uninstall.sh` | Bootstrap / remove a machine |
| `bin/dsh-sync.sh` | The updater (build → smoke test → swap, or keep last good) |
| `bin/dsh-go.mjs` / `bin/dsh-url.sh` | The `:3081` entry / the URL helper |
| `bin/dsh-check-gui.mjs` | Browser acceptance check |
| `plugins/dsh-ops-operator-surface.mjs` | The one DSH plugin this repo ships |
| `harness/cordis.patch.web.yml` | The web profile layer it installs |
| `systemd/` | `dsh-web`, `dsh-go`, `dsh-update` + daily timer |
| `dsh-ops.conf.example` | Config template |

The longer reasoning — why `0.0.0.0` needs a profile-layer patch, what the two
trust fences are, why the Models page needs that plugin — is in
[DESIGN.md](DESIGN.md).
