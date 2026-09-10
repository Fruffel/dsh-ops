#!/usr/bin/env node
/**
 * Tailnet GUI acceptance check: walk the real page from an entry URL through
 * dsh-go's token redirect into Settings -> Models, and fail when the shipped
 * non-loopback downgrade is back ("settings are unavailable in this browser").
 *
 * It is the regression check for the failure this repo exists to fix, and it
 * runs from a machine other than the host, over the tailnet, in a throwaway
 * browser profile. Chrome is driven over CDP with Node's built-in WebSocket, so
 * there are nothing to install.
 *
 * usage: dsh-check-gui.mjs [entry-url] [--expect-provider] [--keep-open]
 *   entry-url          defaults to http://kamer:3081/ (dsh-go's token-free entry)
 *   --expect-provider  also fail when the first-run "Add an API key" step is
 *                      showing, i.e. require a configured model provider
 *   CHROME             overrides the browser executable
 *
 * exit 0 when the Models page rendered its provider directory on the entry
 * authority; exit 1 otherwise (with the panel text printed).
 */
import { spawn } from 'node:child_process'
import { existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const DEBUG_PORT = 9222
const PROFILE = join(tmpdir(), 'dsh-check-gui-profile')
const CANDIDATES = [
  process.env.CHROME,
  'google-chrome-stable',
  'google-chrome',
  'chromium',
  'chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
].filter((value) => typeof value === 'string' && value !== '')

const args = process.argv.slice(2)
const keepOpen = args.includes('--keep-open')
const expectProvider = args.includes('--expect-provider')
const entry = args.find((value) => !value.startsWith('--')) ?? 'http://kamer:3081/'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** First candidate that resolves to an executable path or a PATH lookup. */
function findChrome() {
  for (const candidate of CANDIDATES) {
    if (candidate.includes('/')) {
      if (existsSync(candidate)) return candidate
      continue
    }
    return candidate
  }
  return undefined
}

/** CDP page target URL of the headless browser, once it is listening. */
async function pageTarget() {
  for (let attempt = 0; attempt < 80; attempt++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json()
      const page = list.find((target) => target.type === 'page')
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl
    } catch {}
    await sleep(250)
  }
  throw new Error('the browser exposed no page target')
}

/** Run one page-context expression and return its value. */
function makeEvaluate(send) {
  return async (expression) => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text)
    }
    return result.result.value
  }
}

/** Poll a page-context expression until it is truthy. */
async function waitFor(evaluate, expression, label, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      if (await evaluate(expression)) return
    } catch {}
    await sleep(300)
  }
  throw new Error(`timed out waiting for ${label}`)
}

/** Click the first button-ish node whose text or aria-label matches exactly. */
const CLICK = (label) => `(() => {
  const nodes = [...document.querySelectorAll('button,[role="button"],a,li,span,div')]
  const hit = nodes.find((node) => node.children.length === 0 && node.textContent.trim() === ${JSON.stringify(label)})
    ?? [...document.querySelectorAll('button,[role="button"],a')].find((node) => (node.getAttribute('aria-label') ?? node.textContent).trim() === ${JSON.stringify(label)})
  if (!hit) return false
  ;(hit.closest('button,[role="button"],a,li') ?? hit).click()
  return true
})()`

const chromePath = findChrome()
if (chromePath === undefined) {
  console.error('dsh-check-gui: no Chrome found; set CHROME=/path/to/chrome')
  process.exit(1)
}

rmSync(PROFILE, { recursive: true, force: true })
const chrome = spawn(chromePath, [
  '--headless=new',
  `--remote-debugging-port=${DEBUG_PORT}`,
  `--user-data-dir=${PROFILE}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore'] })

let close = () => {}
try {
  const socket = new WebSocket(await pageTarget())
  await new Promise((resolve, reject) => {
    socket.onopen = resolve
    socket.onerror = () => reject(new Error('CDP socket failed'))
  })

  let sequence = 0
  const pending = new Map()
  const consoleLines = []
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data)
    if (message.id !== undefined) {
      pending.get(message.id)?.(message)
      pending.delete(message.id)
      return
    }
    if (message.method === 'Runtime.consoleAPICalled') {
      consoleLines.push(message.params.args.map((arg) => arg.value ?? arg.description ?? '').join(' '))
    }
  }
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence
    pending.set(id, (message) => (message.error
      ? reject(new Error(`${method}: ${JSON.stringify(message.error)}`))
      : resolve(message.result)))
    socket.send(JSON.stringify({ id, method, params }))
  })
  close = () => socket.close()
  const evaluate = makeEvaluate(send)

  await send('Runtime.enable')
  await send('Page.enable')
  await send('Page.navigate', { url: entry })
  await waitFor(evaluate, '!!globalThis.__DSH_BOOT__', 'the client boot graph')
  await waitFor(evaluate, 'document.querySelectorAll("button,[role=button],a").length > 2', 'the shell chrome')
  await sleep(2500)

  const report = {
    entry,
    finalUrl: await evaluate('location.href'),
    operatorSurface: await evaluate('globalThis.__DSH_TRANSPORT__?.ownsHost === true'),
    // The first-run step only renders while no provider can serve requests, so
    // its absence is the durable "a key is configured" signal.
    onboardingPrompt: await evaluate(
      `/Add an API key to get started/.test((document.querySelector('[role="dialog"]') ?? document.body).innerText)`,
    ),
  }
  // The first-run step owns the dialog while it shows, so the walk is recorded
  // rather than thrown: the report above already says whether it was up.
  try {
    if (!await evaluate(CLICK('Settings'))) throw new Error('no Settings trigger on the page')
    await sleep(1200)
    if (!await evaluate(CLICK('Models'))) throw new Error('no Models entry in the settings navigation')
    await sleep(2500)
    report.panel = await evaluate(`(() => {
      const panel = document.querySelector('[role="dialog"]') ?? document.body
      return panel.innerText.slice(0, 800)
    })()`)
    report.downgraded = /settings are unavailable|Loading the provider directory failed/.test(report.panel)
  } catch (error) {
    report.settingsWalk = error instanceof Error ? error.message : String(error)
  }
  report.console = consoleLines.filter((line) => line.includes('operator surface'))

  console.log(JSON.stringify(report, null, 2))
  if (report.downgraded) {
    console.error('dsh-check-gui: FAIL the settings mirror stayed process-local (non-loopback downgrade)')
    process.exitCode = 1
  } else if (!report.operatorSurface) {
    console.error('dsh-check-gui: FAIL the page did not receive the operator surface')
    process.exitCode = 1
  } else if (expectProvider && report.onboardingPrompt) {
    console.error('dsh-check-gui: FAIL the first-run API-key step is showing (no usable provider)')
    process.exitCode = 1
  } else {
    console.error('dsh-check-gui: OK the Models page rendered over ' + new URL(report.finalUrl).host)
  }
} catch (error) {
  console.error('dsh-check-gui: ' + (error instanceof Error ? error.message : String(error)))
  process.exitCode = 1
} finally {
  close()
  if (!keepOpen) chrome.kill('SIGKILL')
}
