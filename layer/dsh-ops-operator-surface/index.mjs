/**
 * dsh-ops operator surface — give deliberately reached remote authorities the
 * browser's privileged surface.
 *
 * Why this exists
 * ---------------
 * The shipped Web client grants its privileged surface only to a page whose
 * authority is loopback: `ctx.connection.isLoopback` is computed in the browser
 * from `location.hostname` (or a carrier hook), and `dsh-client-ui-settings`
 * turns host-backed settings into process-local memory for every other page:
 *
 *   const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'
 *
 * A page served on a tailnet name therefore reports "settings are unavailable
 * in this browser" on the Models page (and every other settings namespace),
 * however it authenticated. That is upstream's deliberate default, not a bug:
 * see .agents/notes/implemented/bug-fix/2026-08-06-host-backed-web-preferences.md
 * ("The Client keeps Host persistence disabled on non-loopback pages") and the
 * /api trust fence note (2026-07-28-api-browser-trust-boundary.md, "a custom
 * non-loopback composition must trust its serving authorities").
 *
 * What this plugin does
 * ---------------------
 * `webserver/index-inject` is the documented seam for index-page bootstrap rows
 * (dsh-host-webserver), and `__DSH_TRANSPORT__` is the documented carrier hook a
 * shell-owned page uses to declare that its page owns the Host
 * (dsh-client-connection, ClientTransportHooks.ownsHost). This plugin combines
 * the two: for the authorities this deployment serves — the ones already named
 * to the /api fence — the served page declares `ownsHost`, so the browser
 * treats a tailnet page as the operator's own surface instead of downgrading
 * it.
 *
 * What this plugin does NOT do
 * ----------------------------
 * It grants no reachability and no identity. The /api Host/Origin fence still
 * refuses any authority that is not loopback or listed in `trustedHosts`, and
 * every RPC still requires the signed browser cookie minted from the launch
 * token. An authority that can load this page could already run shell commands
 * through it; settings persistence is the smaller privilege.
 *
 * Reversibility
 * -------------
 * Remove this row's `insert` entry from the profile's cordis.patch.yml and
 * every page returns to loopback-only behavior.
 */

/** Loader-visible plugin name (the loader prints it in boot diagnostics). */
export const name = 'dsh-ops-operator-surface'

/** Authority shape accepted by config.authorities: a bare `host` or `host:port`. */
const AUTHORITY = /^[A-Za-z0-9._:[\]-]+$/

/**
 * Read and validate the optional `authorities` config field.
 * @param config - the loader entry config; absent for a config-less row.
 * @returns the configured authorities, verbatim and in order.
 */
function configuredAuthorities(config) {
  const value = config?.authorities
  if (value === undefined) return []
  if (!Array.isArray(value) || value.some(entry => typeof entry !== 'string' || !AUTHORITY.test(entry))) {
    throw new Error(`${name}: config.authorities must be a list of bare host[:port] authorities`)
  }
  return value
}

/**
 * Render the page-side switch. Baked as an inline classic script ahead of the
 * client bundles so `__DSH_TRANSPORT__` is readable when dsh-client-connection
 * applies. `<` is escaped so a configured authority can never close the
 * script element.
 * @param authorities - the authorities that receive the operator surface.
 * @returns the inline script body.
 */
function switchScript(authorities) {
  const list = JSON.stringify(authorities).replaceAll('<', '\\u003c')
  return `(() => {
	const authorities = ${list};
	const host = location.host.toLowerCase();
	const hostname = location.hostname.toLowerCase();
	const operator = authorities.some((entry) => entry.includes(':') ? host === entry : hostname === entry);
	if (!operator) return;
	globalThis.__DSH_TRANSPORT__ = { ...globalThis.__DSH_TRANSPORT__, ownsHost: true };
	console.info('[dsh-ops] operator surface on ' + host);
})()`
}

/**
 * Answer every index-injection collection with the operator-surface switch.
 *
 * The injection table is collected per served index request, so the authorities
 * are read from the live `webRuntime` service at emit time rather than captured
 * at load: the deployment's `--trusted-host` values and, under an all-interfaces
 * bind, the LAN literals it derives.
 * @param ctx - host context (root-level row; the webserver emits upward to it).
 * @param config - loader entry config carrying optional extra `authorities`.
 */
export function apply(ctx, config) {
  const extra = configuredAuthorities(config)
  ctx.on('webserver/index-inject', (table) => {
    const runtime = ctx.get('webRuntime')
    const authorities = [...new Set([...(runtime?.trustedHosts ?? []), ...extra])]
    if (authorities.length === 0) return
    table.push({ kind: 'script', placement: 'head', text: switchScript(authorities) })
  })
}
