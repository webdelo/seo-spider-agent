#!/usr/bin/env node
// ShareSpider's local Chrome / Playwright bridge for the Google Search Console
// Links report.  The public GSC API does not expose this report.  We therefore
// use a locally running, user-owned Chrome profile and import only the exported
// CSV into ShareSpider.  No credentials are read, copied, or sent anywhere.

import { chromium } from 'playwright-core';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

const argumentsByName = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (key?.startsWith('--') && value) argumentsByName.set(key.slice(2), value);
}

const target = argumentsByName.get('target');
const output = argumentsByName.get('output');
const status = argumentsByName.get('status');
const cdpURL = argumentsByName.get('cdp') ?? 'http://127.0.0.1:9222';

function fail(message, code = 1) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}
if (!target || !output || !status) fail('Missing target, output or status path.');

async function writeStatus(state, message, extra = {}) {
  await mkdir(dirname(status), { recursive: true });
  await writeFile(status, JSON.stringify({ state, message, updatedAt: new Date().toISOString(), ...extra }), 'utf8');
}

async function firstVisible(locator) {
  const count = await locator.count();
  for (let index = 0; index < count; index += 1) {
    const item = locator.nth(index);
    if (await item.isVisible().catch(() => false)) return item;
  }
  return null;
}

async function waitForFirstVisible(locator, timeout = 8_000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeout) {
    const item = await firstVisible(locator);
    if (item) return item;
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  return null;
}

try {
  await writeStatus('connecting', 'Connecting to local ShareSpider Chrome.');
  const browser = await chromium.connectOverCDP(cdpURL, { timeout: 10_000 });
  const context = browser.contexts()[0];
  if (!context) fail('The managed Chrome profile is unavailable.');

  let page = context.pages().find(item => item.url().includes('search.google.com/search-console'));
  if (!page) page = await context.newPage();
  const resource = encodeURIComponent(target);
  await page.goto(`https://search.google.com/search-console/links?resource_id=${resource}`, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await page.waitForTimeout(2_500);

  const pageText = await page.locator('body').innerText().catch(() => '');
  if (/sign in|войти|choose an account|выберите аккаунт/i.test(pageText)) {
    await writeStatus('needs-sign-in', 'Sign in to Google Search Console in the ShareSpider Chrome window. ShareSpider is waiting and will continue automatically.');
    fail('Google sign-in is required in the ShareSpider Chrome window.');
  }
  if (/oops[,!]?\s*you (?:don't|do not) have access to this property|нет доступа к этому ресурсу|нет доступа к этому объекту/i.test(pageText)) {
    await writeStatus('access-denied', 'Google Search Console access denied for this property. ShareSpider stopped the Chrome links check.');
    fail('Google Search Console access denied for this property.');
  }

  // The Links page differs by GSC language and roll-out.  First open the
  // export menu using accessible names, then select its CSV action.  The
  // alternatives are deliberate: English and Russian GSC are both common.
  const exportButton = await firstVisible(page.locator('[aria-label*="Export" i], [aria-label*="Экспорт" i]'))
    ?? await firstVisible(page.getByRole('button', { name: /export|экспорт/i }));
  if (!exportButton) {
    await writeStatus('export-unavailable', 'The GSC Links export control was not found. Open the Links report for this property in the ShareSpider Chrome window and retry.');
    fail('The Google Search Console Links export control was not found.');
  }

  // Close a stale menu from a preceding manually started attempt. Otherwise
  // the same click only toggles that menu closed.
  await page.keyboard.press('Escape').catch(() => {});
  await page.keyboard.press('Escape').catch(() => {});
  await exportButton.click();

  // The first menu selects the report flavour, not the file format.  Exporting
  // the summary screen does not produce a donor-link CSV, so always request
  // the full "More sample links" report before opening the format chooser.
  const moreSampleLinks = await waitForFirstVisible(page.getByRole('menuitem', { name: /more sample links|больше примеров ссылок/i }))
    ?? await waitForFirstVisible(page.locator('[aria-label*="More sample links" i], [aria-label*="Больше примеров ссылок" i]'));
  if (!moreSampleLinks) {
    await writeStatus('export-unavailable', 'The "More sample links" action was not found in the GSC export menu.');
    fail('The Google Search Console "More sample links" action was not found.');
  }
  await moreSampleLinks.click();

  const csvAction = await waitForFirstVisible(page.getByRole('menuitem', { name: /download csv|csv|скачать csv/i }))
    ?? await waitForFirstVisible(page.getByRole('button', { name: /download csv|csv|скачать csv/i }))
    ?? await waitForFirstVisible(page.locator('[aria-label*="Download CSV" i], [aria-label*="Скачать CSV" i]'))
    ?? await waitForFirstVisible(page.getByText(/download csv|csv|скачать csv/i));
  if (!csvAction) {
    await writeStatus('export-unavailable', 'The CSV action was not found in the GSC export menu.');
    fail('The Google Search Console CSV action was not found.');
  }
  const downloadPromise = page.waitForEvent('download', { timeout: 30_000 });
  await csvAction.click();
  const download = await downloadPromise;
  await mkdir(dirname(output), { recursive: true });
  await download.saveAs(output);
  await writeStatus('completed', 'Google Search Console Links CSV exported and ready to import.', { output });
  await browser.close();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  await writeStatus('failed', message).catch(() => {});
  fail(message);
}
