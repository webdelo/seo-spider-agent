#!/usr/bin/env node
// Exports the Page Indexing table through the already-authorised local Chrome
// profile.  GSC does not publish this coverage report through a public API.
import { mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { basename, dirname, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
// The production app supplies the local Playwright runtime path.  The fallback
// keeps the development build usable without a separate npm install.
const playwrightCorePath = process.env.SHARESPIDER_PLAYWRIGHT_CORE || '/Users/daniilspara/Documents/App/ShareSpider/MCP/node_modules/playwright-core/index.mjs';
const { chromium } = await import(playwrightCorePath);

const execFileAsync = promisify(execFile);

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1]]);
  return pairs;
}, []));
const target = String(args.target ?? '').trim();
const output = resolve(String(args.output ?? 'gsc-page-indexing-export.csv'));
const status = resolve(String(args.status ?? 'gsc-page-indexing-status.json'));

async function setStatus(state, message, extra = {}) {
  await mkdir(dirname(status), { recursive: true });
  await writeFile(status, JSON.stringify({ state, message, updatedAt: new Date().toISOString(), ...extra }, null, 2));
}
function normalizedTarget(value) {
  const url = new URL(value);
  url.hash = ''; url.search = '';
  return `${url.protocol}//${url.host}/`;
}
function hasCoverageColumns(text) {
  const header = text.split(/\r?\n/, 1)[0].toLowerCase();
  return /reason|причин|issue/.test(header) && /pages?|страниц|urls?/.test(header);
}
async function findExportButton(page) {
  const selectors = [
    '[aria-label="EXPORT"]:visible',
    '[aria-label*="Export" i]:visible', '[aria-label*="Экспорт" i]:visible',
    'button:has-text("Export")', 'button:has-text("Экспорт")',
    '[role="button"]:has-text("Export")', '[role="button"]:has-text("Экспорт")'
  ];
  for (const selector of selectors) {
    const candidate = page.locator(selector).first();
    if (await candidate.count() && await candidate.isVisible().catch(() => false)) return candidate;
  }
  return null;
}
async function findCSVItem(page) {
  const selectors = [
    '[aria-label="Download CSV"]:visible', '[aria-label="Скачать CSV"]:visible',
    '[role="menuitem"][aria-label*="CSV" i]:visible',
    '[role="menuitem"]:has-text("Download CSV"):visible', '[role="menuitem"]:has-text("Скачать CSV"):visible'
  ];
  for (const selector of selectors) {
    const candidate = page.locator(selector).first();
    if (await candidate.count() && await candidate.isVisible().catch(() => false)) return candidate;
  }
  return null;
}

async function openExportMenu(page) {
  // GSC keeps the last-opened menu in the DOM. Do not click Export a second
  // time: that simply closes the menu and used to make the importer fall back
  // to the ten visible example URLs.
  if (await findCSVItem(page)) return;
  const button = await findExportButton(page);
  if (!button) throw new Error('The Page Indexing Export button was not found. Open the report in the dedicated ShareSpider Chrome profile and confirm that this Google account has access to the selected property.');
  await button.click({ noWaitAfter: true });
  await page.waitForTimeout(250);
}

async function exportDetailThroughGoogleSheets(page, reason) {
  // In a Chrome instance attached over CDP, GSC's “Download CSV” browser
  // download does not reliably emit a Playwright download event.  Its Google
  // Sheets export is the same report, includes every affected URL, and can be
  // read back as CSV from the already authorised browser session.
  await openExportMenu(page);
  const sheetsItem = page.locator('[aria-label="Google Sheets"]:visible, [aria-label="Таблицы Google"]:visible').first();
  if (!await sheetsItem.count()) throw new Error(`The Google Sheets export action was not found for ${reason}.`);

  const context = page.context();
  const existing = new Set(context.pages().map(candidate => candidate.url()));
  await sheetsItem.click({ noWaitAfter: true, timeout: 10_000 });

  let sheet = null;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    await page.waitForTimeout(500);
    sheet = context.pages().find(candidate => candidate.url().includes('docs.google.com/spreadsheets/d/') && !existing.has(candidate.url()));
    if (sheet) break;
  }
  if (!sheet) throw new Error(`Google Sheets export did not open for ${reason}.`);
  // GSC creates Chart, Table and Metadata sheets asynchronously.  The Table
  // tab is the only one with the complete URL list.  Do not fall back to the
  // 10 visible rows in GSC while this tab is still being created.
  const tableTab = sheet.locator('.docs-sheet-tab').filter({ hasText: /^(Table|Таблица)$/i }).last();
  await tableTab.waitFor({ state: 'visible', timeout: 30_000 });
  const chartURL = sheet.url();
  await tableTab.click({ noWaitAfter: true, timeout: 10_000 });
  await sheet.waitForFunction(previousURL => location.href !== previousURL, chartURL, { timeout: 15_000 }).catch(() => {});
  await sheet.waitForTimeout(1_000);
  const match = sheet.url().match(/\/spreadsheets\/d\/([^/]+)\/edit\?(?:[^#]*&)?gid=(\d+)/);
  if (!match) throw new Error(`The Google Sheets export URL was incomplete for ${reason}.`);
  const [, documentID, gid] = match;
  const csv = await sheet.evaluate(async ({ documentID, gid }) => {
    const response = await fetch(`/spreadsheets/d/${documentID}/export?format=csv&gid=${gid}`);
    if (!response.ok) throw new Error(`Google Sheets CSV export returned HTTP ${response.status}`);
    return response.text();
  }, { documentID, gid });
  if (!/^URL[,а-я]/im.test(csv)) throw new Error(`The exported Google Sheets tab did not contain URLs for ${reason}.`);
  await sheet.close().catch(() => {});
  return csv;
}

async function downloadCSVText(page, destination) {
  await openExportMenu(page);
  const item = await findCSVItem(page);
  if (!item) throw new Error('The Page Indexing CSV menu item was not found. Google may have changed the report interface.');
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 30_000 }),
    item.click({ noWaitAfter: true })
  ]);
  const temporary = `${destination}.download`;
  await download.saveAs(temporary);
  // Google currently delivers Page Indexing exports as a ZIP file even after
  // the user chose “Download CSV”.  Treat it as an archive, rather than
  // waiting forever for a non-existent direct CSV download.
  const archive = await readFile(temporary);
  const isZip = archive.length > 3 && archive[0] === 0x50 && archive[1] === 0x4b;
  const text = isZip
    ? (await execFileAsync('/usr/bin/unzip', ['-p', temporary], { maxBuffer: 20 * 1024 * 1024 })).stdout
    : archive.toString('utf8');
  await rm(temporary, { force: true });
  // GSC has changed the localised CSV header several times.  Keep the raw
  // export: Swift validates and parses it afterwards.  Rejecting it here used
  // to discard a perfectly valid report before the importer could inspect it.
  return text;
}

async function exportCSV(page) {
  const text = await downloadCSVText(page, output);
  await writeFile(output, text, 'utf8');
  return text;
}

function csvField(value) {
  return `"${String(value ?? '').replaceAll('"', '""')}"`;
}

async function scrapeCoverageTable(page, pageIndexURL, targetHost) {
  // The Page Indexing report's Export menu only exports the time-series chart.
  // The live report table contains the actual category counts we need.  Read it
  // through the authorised Chrome session and produce an equivalent CSV for
  // the same Swift importer used by manual exports.
  await page.locator('table').first().waitFor({ state: 'visible', timeout: 20_000 }).catch(() => {});
  const rows = await page.locator('table').evaluateAll(tables => {
    for (const table of tables) {
      const headers = Array.from(table.querySelectorAll('th')).map(node => (node.textContent || '').trim().toLowerCase());
      if (!headers.some(value => /reason|причин|issue/.test(value)) || !headers.some(value => /pages?|страниц|urls?/.test(value))) continue;
      return Array.from(table.querySelectorAll('tbody tr')).map(row => {
        const cells = Array.from(row.querySelectorAll('td'));
        const reason = (cells[0]?.textContent || '').trim().replace(/\s+/g, ' ');
        const countCell = cells.find(cell => cell.hasAttribute('data-numeric-value'));
        const count = countCell?.getAttribute('data-numeric-value') || '';
        return { reason, count };
      }).filter(row => row.reason && /^\d+$/.test(row.count));
    }
    return [];
  });
  const body = await page.locator('body').innerText();
  const indexed = body.match(/(?:^|\n)Indexed\s+(\d+)(?:\n|$)/i)?.[1] || body.match(/(?:^|\n)Проиндексирован\w*\s+(\d+)(?:\n|$)/i)?.[1] || '';
  const notIndexed = body.match(/(?:^|\n)Not indexed\s+(\d+)(?:\n|$)/i)?.[1] || body.match(/(?:^|\n)Не проиндексирован\w*\s+(\d+)(?:\n|$)/i)?.[1] || '';
  const summary = [];
  if (indexed) summary.push({ reason: 'Indexed', count: indexed });
  if (notIndexed) summary.push({ reason: 'Not Indexed', count: notIndexed });
  // Each category opens a drill-down that has its own Download CSV action.
  // Export every category, rather than retaining the ten examples initially
  // shown by GSC. This is intentionally unbounded: Google controls the number
  // of rows in a report, and ShareSpider preserves the complete export.
  const samples = new Map();
  const categoryDirectory = resolve(dirname(output), `${basename(output, '.csv')}-categories`);
  await mkdir(categoryDirectory, { recursive: true });
  const safeFilename = value => value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 70) || 'category';
  const urlsFromText = text => {
    const escapedHost = targetHost.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const expression = new RegExp(`https?://${escapedHost}(?:/[^\\s"'<>]*)?`, 'gi');
    return Array.from(new Set((text.match(expression) ?? []).map(value => value.replace(/[),.;]+$/, ''))));
  };
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index];
    try {
      await setStatus('running', `Exporting all affected URLs for: ${row.reason}`, { completed: index + 1, total: rows.length });
      // Go back first: the detail view replaces the original category table.
      await page.goto(pageIndexURL, { waitUntil: 'domcontentloaded', timeout: 20_000 });
      await page.waitForTimeout(900);
    const source = page.locator('table tbody tr').filter({ hasText: row.reason }).first();
      if (!await source.count() || !await source.isVisible().catch(() => false)) continue;
      await Promise.all([
        page.waitForURL(url => url.href !== pageIndexURL, { timeout: 12_000 }).catch(() => {}),
        source.click({ timeout: 10_000 })
      ]);
      await page.waitForTimeout(1_000);
      const detailFile = resolve(categoryDirectory, `${String(index + 1).padStart(2, '0')}-${safeFilename(row.reason)}.csv`);
      let detail = '';
      try {
        detail = await exportDetailThroughGoogleSheets(page, row.reason);
        await writeFile(detailFile, detail, 'utf8');
      } catch (error) {
        await setStatus('running', `Could not export all URLs for ${row.reason}: ${error.message}. Continuing with the next category.`, { completed: index + 1, total: rows.length });
      }
      let urls = urlsFromText(detail);
      if (!urls.length) urls = urlsFromText(await page.locator('body').innerText());
      if (urls.length) samples.set(row.reason, urls);
    } catch (_) {
      // A category can be unavailable in a particular property. Keep its
      // count from the overview and continue exporting every other category.
    }
  }
  const all = [...summary, ...rows];
  if (!all.length) return null;
  const lines = ['Reason,Pages,URL', ...all.map(row => `${csvField(row.reason)},${csvField(row.count)},` )];
  for (const row of rows) {
    for (const url of samples.get(row.reason) ?? []) lines.push(`${csvField(row.reason)},,${csvField(url)}`);
  }
  return lines.join('\n');
}

try {
  if (!target) throw new Error('A target property URL is required.');
  await mkdir(dirname(output), { recursive: true });
  await rm(output, { force: true });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const context = browser.contexts()[0];
  if (!context) throw new Error('The ShareSpider Chrome profile is not ready.');
  const pageIndexURL = `https://search.google.com/search-console/index?resource_id=${encodeURIComponent(normalizedTarget(target))}`;
  // Never reuse a visible or another importer's GSC tab.  Reusing it allowed
  // two concurrent site checks to switch each other's selected property and
  // write a report for the wrong domain.
  const page = await context.newPage();
  await page.goto(pageIndexURL, { waitUntil: 'domcontentloaded', timeout: 25_000 });
  await page.waitForTimeout(4_000);
  const body = (await page.locator('body').innerText()).toLowerCase();
  if (/sign in|войти|вход в аккаунт/.test(body)) {
    await setStatus('needs-sign-in', 'Sign in to Google in the dedicated ShareSpider Chrome profile. ShareSpider is waiting and will continue automatically.');
    process.exitCode = 2;
  } else if (/oops[,!]?\s*you (?:don't|do not) have access to this property|нет доступа к этому ресурсу|нет доступа к этому объекту/i.test(body)) {
    throw new Error('Google Search Console access denied for this property. ShareSpider stopped the Chrome Page Indexing check.');
  } else {
    const csv = await scrapeCoverageTable(page, pageIndexURL, new URL(normalizedTarget(target)).hostname) ?? await exportCSV(page);
    await writeFile(output, csv, 'utf8');
    await setStatus('completed', 'Google Search Console Page Indexing report imported from the live report table.', { bytes: Buffer.byteLength(csv) });
  }
  await browser.close();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  await setStatus('failed', message);
  console.error(message);
  process.exitCode = 1;
}
