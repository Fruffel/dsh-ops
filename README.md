# dsh-ops

Small ops project that runs the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh web`) **from source** on `kamer-ts` and exposes it on the tailnet.

## Layout

| Path | What |
| --- | --- |
| `harness/upstream` | Full git clone of `deepseek-ai/deepseek-harness` (never built here) |
| `harness/builds/<tag>` | One git worktree per built tag |
| `harness/current` | Symlink to the build the service runs |
| `bin/dsh-sync.sh` | Smart updater: newest tag on a channel → build → smoke test → swap, or keep last good |
| `bin/dsh-url.sh` | Prints the current `?token=` URLs (local, tailnet IP, MagicDNS) |
| `proxy/tailscale-proxy.mjs` | User-space TCP forwarder: tailnet `:3080` → `127.0.0.1:3080` |
| `systemd/` | User units: `dsh-web`, `dsh-proxy`, `dsh-update` (+ daily 03:00 timer) |
| `install.sh` | Bootstrap a machine: node check, pnpm, units, aliases |

## Design notes

- DSH only binds `127.0.0.1` via its CLI (`--host 0.0.0.0` is refused there),
  so tailnet reachability comes from the web profile's user patch layer
  (`harness/cordis.patch.web.yml` → `~/.dsh/profiles/web/cordis.patch.yml`),
  which restates the `webserver` row with `host: '0.0.0.0'`. Bound this way
  the harness also auto-trusts its own IP literals (LAN + tailnet) for `/api`.
  Token+cookie auth still guards everything.
- `--trusted-host kamer --trusted-host kamer.tail39c8ca.ts.net` covers
  hostname (non-IP) authorities through the `/api` browser-trust fence.
- `proxy/tailscale-proxy.mjs` is a kept fallback (loopback DSH + forwarder
  bound to the tailnet IP only). Not used by default.
- The `?token=` URL is needed **once**; it mints a cookie (patched to 365 days
  in `~/.dsh/profiles/web/cordis.patch.yml`) that survives restarts and updates.
- `DSH_HOME` (`~/.dsh`: profiles, credentials, sessions) is untouched by syncs.

## Usage

```sh
dsh-update                 # sync to newest rc tag, build, swap, restart
dsh-update --channel stable
dsh-update --ref dsh-v0.1.5-rc.1   # pin / roll back to a tag
dsh-update --dry-run       # show what would happen
dsh-url                    # current token URLs
dsh-logs                   # follow both services
```
