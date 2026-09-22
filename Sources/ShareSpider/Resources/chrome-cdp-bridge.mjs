import readline from 'node:readline';
import { spawn } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';

const corePath = process.env.SHARESPIDER_PLAYWRIGHT_CORE;
if (!corePath) throw new Error('playwright-core is unavailable for the Chrome CDP bridge.');
const { chromium } = await import(corePath);

let browser;
let context;
let dedicatedChrome;
let connecting;
const pageSlots = [];
const pageWaiters = [];
const maxConcurrentPages = 2;
const inspectionTimeoutMilliseconds = 30_000;

async function debuggerEndpoint(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(3_000) });
  const version = await response.json();
  if (!version.webSocketDebuggerUrl) throw new Error('Local Chrome did not provide a CDP WebSocket endpoint.');
  return version.webSocketDebuggerUrl;
}

async function connectPort(port, timeout = 12_000) {
  const endpoint = await debuggerEndpoint(port);
  return await chromium.connectOverCDP(endpoint, { timeout });
}

async function startDedicatedChrome() {
  if (!dedicatedChrome || dedicatedChrome.exitCode !== null) {
    const executable = process.env.SHARESPIDER_CHROME_EXECUTABLE;
    if (!executable) throw new Error('Google Chrome was not found. Install Google Chrome, then try again.');
    const profile = path.join(os.homedir(), 'Library', 'Application Support', 'ShareSpider', 'ChromeCrawlerProfile');
    dedicatedChrome = spawn(executable, [
      '--remote-debugging-port=9223',
      `--user-data-dir=${profile}`,
      // Keep the crawler browser out of the user's workspace. It is a real
      // local Chrome process with a persistent profile, but has no visible UI.
      '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-networking'
    ], { stdio: 'ignore' });
  }
  let lastError;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try { return await connectPort(9223, 15_000); }
    catch (error) { lastError = error; await new Promise(resolve => setTimeout(resolve, 500)); }
  }
  throw lastError ?? new Error('Dedicated local Chrome did not start.');
}

async function connect() {
  if (browser?.isConnected()) return;
  if (connecting) return await connecting;
  connecting = (async () => {
    // Never attach the crawler to the interactive GSC browser. The crawler
    // owns a separate headless Chrome profile so its tabs, workers and cookies
    // cannot interfere with a user-driven Search Console export.
    try { browser = await connectPort(9223); }
    catch { browser = await startDedicatedChrome(); }
    context = browser.contexts()[0] ?? await browser.newContext();
    browser.on('disconnected', () => {
      browser = undefined; context = undefined; pageSlots.length = 0;
    });
  })();
  try { await connecting; } finally { connecting = undefined; }
}

async function acquirePage() {
  await connect();
  while (true) {
    const idle = pageSlots.find(slot => !slot.busy);
    if (idle) { idle.busy = true; return idle; }
    if (pageSlots.length < maxConcurrentPages) {
      const slot = { page: undefined, busy: true };
      pageSlots.push(slot);
      try { slot.page = await context.newPage(); return slot; }
      catch (error) { pageSlots.splice(pageSlots.indexOf(slot), 1); throw error; }
    }
    // A signal rather than a slot lets a discarded page be replaced cleanly.
    await new Promise(resolve => pageWaiters.push(resolve));
  }
}

function releasePage(slot) {
  slot.busy = false;
  pageWaiters.shift()?.();
}

async function discardPage(slot) {
  const index = pageSlots.indexOf(slot);
  if (index >= 0) pageSlots.splice(index, 1);
  try { await slot.page?.close({ runBeforeUnload: false }); } catch {}
  // Wake one waiting request so it can create a clean replacement tab.
  pageWaiters.shift()?.();
}

async function withDeadline(work, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      work(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('ShareSpider CDP inspection timed out.')), milliseconds);
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function inspect(request) {
  let slot;
  let discardSlot = false;
  try {
    slot = await acquirePage();
    const { response, html } = await withDeadline(async () => ({
      response: await slot.page.goto(request.url, { waitUntil: 'domcontentloaded', timeout: 20_000 }),
      html: await slot.page.content()
    }), inspectionTimeoutMilliseconds);
    // Keep the IPC response bounded. Status verification remains useful even
    // when a rare HTML document is too large to send back for parsing.
    const body = Buffer.byteLength(html) <= 4 * 1024 * 1024 ? Buffer.from(html).toString('base64') : '';
    process.stdout.write(JSON.stringify({
      id: request.id,
      status: response?.status() ?? null,
      url: slot.page.url(),
      contentLength: Buffer.byteLength(html),
      contentType: await response?.headerValue('content-type') ?? '',
      htmlBase64: body,
      error: body ? '' : 'Chrome page is larger than the local parsing limit.'
    }) + '\n');
  } catch (error) {
    discardSlot = String(error?.message ?? error).includes('timed out');
    process.stdout.write(JSON.stringify({ id: request.id, status: null, url: '', contentLength: 0, contentType: '', error: String(error?.message ?? error) }) + '\n');
  } finally {
    if (slot) {
      if (discardSlot) await discardPage(slot);
      else releasePage(slot);
    }
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  try {
    const request = JSON.parse(line);
    // A fixed two-tab pool keeps CDP bounded while preserving one profile and
    // its cookies for the complete crawl.
    void inspect(request);
  } catch (error) {
    process.stdout.write(JSON.stringify({ id: '', status: null, url: '', contentLength: 0, error: String(error?.message ?? error) }) + '\n');
  }
}
