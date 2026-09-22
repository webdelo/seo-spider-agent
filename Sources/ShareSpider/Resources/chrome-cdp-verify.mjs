const corePath = process.env.SHARESPIDER_PLAYWRIGHT_CORE;
if (!corePath) throw new Error('playwright-core is unavailable for the Chrome fallback.');
const { chromium } = await import(corePath);
const args = process.argv.slice(2);
const target = args[args.indexOf('--url') + 1];
if (!target) throw new Error('Missing --url.');

let browser;
try {
  // The direct WebSocket endpoint avoids a flaky HTTP discovery handshake when
  // the user has many GSC tabs open in the same local Chrome profile.
  const versionResponse = await fetch('http://127.0.0.1:9222/json/version', { signal: AbortSignal.timeout(5_000) });
  const version = await versionResponse.json();
  if (!version.webSocketDebuggerUrl) throw new Error('Local Chrome did not provide a CDP WebSocket endpoint.');
  browser = await chromium.connectOverCDP(version.webSocketDebuggerUrl, { timeout: 30_000 });
  const context = browser.contexts()[0];
  const page = await context.newPage();
  const response = await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 15_000 });
  const html = await page.content();
  process.stdout.write(JSON.stringify({ status: response?.status() ?? null, url: page.url(), contentLength: html.length }));
  await page.close();
} catch (error) {
  process.stderr.write(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  await browser?.close().catch(() => {});
}
