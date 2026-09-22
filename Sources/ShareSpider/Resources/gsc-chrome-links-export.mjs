#!/usr/bin/env node
// ShareSpider's local Chrome / Playwright bridge for the Google Search Console
// Links report.  The public GSC API does not expose this report.  We therefore
// use a locally running, user-owned Chrome profile and read the visible report
// table directly.  GSC's CSV action can deliver several unrelated files and
// has proven less reliable than its paginated table. No credentials are read,
// copied, or sent anywhere.

import { access, mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

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
  // The macOS GUI has no terminal; Swift captures this into chrome-launch.log.
  process.stderr.write(`[ShareSpider writeStatus] state=${state} message=${message}\n`);
}

// This helper is launched from the app bundle, whose directory has no
// node_modules.  Resolve Playwright explicitly from the ShareSpider MCP
// runtime instead of relying on Node's module lookup (or NODE_PATH).
async function loadChromium() {
  const candidates = [process.env.SHARESPIDER_PLAYWRIGHT_CORE].filter(Boolean);
  let lastError;
  for (const candidate of candidates) {
    try {
      await access(candidate);
      const module = await import(pathToFileURL(candidate).href);
      if (module.chromium) return module.chromium;
      lastError = new Error(`Playwright runtime at ${candidate} does not export chromium.`);
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error(`Unable to load the bundled Playwright runtime. ${lastError?.message ?? ''}`.trim());
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

// The Links overview has several “More” controls. Pick the one belonging to
// the Top linking sites card, so the table contains referring donors rather
// than a sample of target pages or anchor text.
// NOTE: deliberately avoids page.evaluateAll / evaluate — some CDP-backed
// Chrome builds throw "ErrorCaptureStackTrace" on those calls, which aborts
// the whole export. Plain locator iteration is slower but robust.
async function openTopLinkingSites(page) {
  // GSC renders its visible action as "MORE" followed by a chevron icon, so
  // its accessible text is often "MORE\\n", rather than exactly "More".
  // Match the label as a word/line item while keeping the card-heading check
  // below to distinguish donor domains from the other three More controls.
  const more = /(?:^|\s)(?:more|more sample links|больше|ещ[её]|показать больше)(?:\s|$)/i;
  const heading = /top linking sites|ссылающ(?:иеся|ихся) сайт|домены,? ссылающиеся/i;
  // The GSC shell paints first; its report cards arrive several seconds later.
  // Poll instead of treating a still-loading report as a missing action.
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    // The property-access error can appear after navigation has initially
    // completed. Check it on every poll: once Google has denied access there
    // is no useful control to click and retrying only hammers the same page.
    const pageText = await page.locator('body').innerText({ timeout: 3_000 }).catch(() => '');
    if (/oops[,!]?\s*you\s+(?:do\s*not|don't)\s+have\s+access\s+to\s+this\s+property|you don't have access to this property|нет доступа к (?:этому )?(?:ресурсу|свойству|объекту)/i.test(pageText)) {
      return 'access-denied';
    }
    const controls = page.locator('button, a, [role="button"]');
    const count = await controls.count().catch(() => 0);
    let bestIndex = -1;
    let bestScore = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < count && bestScore !== 0; i += 1) {
      const control = controls.nth(i);
      if (!(await control.isVisible().catch(() => false))) continue;
      const label = ((await control.innerText().catch(() => '')) || (await control.getAttribute('aria-label').catch(() => '')) || '').trim();
      if (!label || !more.test(label)) continue;
      // Walk up the ancestors in page terms, looking for the card heading.
      let node = control.locator('xpath=..');
      let depth = 0;
      let score = Number.MAX_SAFE_INTEGER;
      while (depth < 8) {
        const text = (await node.innerText().catch(() => '')).toLowerCase();
        if (heading.test(text)) {
          const candidate = text.length + depth * 100;
          if (candidate < score) score = candidate;
        }
        node = node.locator('xpath=..');
        depth += 1;
      }
      if (score < bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }
    if (bestIndex >= 0) {
      // GSC frequently re-renders the card between locating and clicking it.
      // A short failed click is retried by the outer polling loop instead of
      // aborting the whole donor import after Playwright's default 30 seconds.
      const clicked = await controls.nth(bestIndex).click({ timeout: 5_000 }).then(() => true).catch(() => false);
      if (clicked) {
        await page.waitForTimeout(1_500);
        return true;
      }
    }
    await page.waitForTimeout(750);
  }
  return 'not-found';
}

// Attach a page snapshot to a status entry so that when an export step fails
// the on-screen message says which page ShareSpider was actually looking at.
async function snapshot(page, message) {
  let hint = '';
  try {
    const url = page.url();
    const raw = await page.locator('body').innerText({ timeout: 3_000 }).catch(() => '');
    const trimmed = raw.split('\n').map(line => line.trim()).filter(Boolean).slice(0, 40).join(' | ');
    hint = ` [${url}] ${message} Page shows: ${trimmed.slice(0, 500)}`;
  } catch {
    hint = ` ${message}`;
  }
  return hint;
}

function csvField(value) {
  return `"${String(value ?? '').replaceAll('"', '""')}"`;
}

function cleanedCell(value) {
  // GSC sometimes appends an invisible helper link after the displayed value.
  return String(value ?? '').split('<', 1)[0].trim().replace(/\s+/g, ' ');
}

async function topLinkingSitesTable(page) {
  const candidates = page.locator('table, [role="table"], [role="grid"]');
  const count = await candidates.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    const table = candidates.nth(index);
    if (!(await table.isVisible().catch(() => false))) continue;
    const header = (await table.locator('th, [role="columnheader"]').allInnerTexts().catch(() => [])).join(' ').toLowerCase();
    if (/top linking sites|linking sites|ссылающ(?:иеся|ихся) сайт|домены,? ссылающиеся/.test(header)) return table;
    // Some GSC variants omit the card title inside the table but retain these
    // two column headings.
    if (/(?:linking site|ссылающийся сайт|домен)/.test(header) && /(?:linking pages|ссылающ(?:иеся|ихся) страниц)/.test(header)) return table;
  }
  return null;
}

async function readDonors(table) {
  const rows = table.locator('tbody tr, [role="row"]');
  const count = await rows.count().catch(() => 0);
  const donors = [];
  for (let index = 0; index < count; index += 1) {
    const row = rows.nth(index);
    if (!(await row.isVisible().catch(() => false))) continue;
    const cells = row.locator('td, [role="cell"]');
    const cellCount = await cells.count().catch(() => 0);
    if (cellCount < 2) continue;
    const values = [];
    for (let cellIndex = 0; cellIndex < cellCount; cellIndex += 1) {
      const cell = cells.nth(cellIndex);
      values.push(cleanedCell(await cell.getAttribute('data-string-value').catch(() => '') || await cell.innerText().catch(() => '')));
    }
    const site = values[0] || '';
    // A donor row is a hostname, while header/pagination rows are not.
    if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/i.test(site.replace(/^www\./i, ''))) continue;
    const linkingPages = Number((values[1] || '').replace(/[^0-9]/g, '')) || 0;
    const targetPages = Number((values[2] || '').replace(/[^0-9]/g, '')) || 0;
    donors.push({ site, linkingPages, targetPages });
  }
  return donors;
}

async function nextTablePage(page, table, previousFirstSite) {
  // Restrict the search to this report's card/container so an unrelated GSC
  // pager cannot be advanced. The parent chain covers both current layouts.
  let container = table;
  for (let depth = 0; depth < 4; depth += 1) {
    const controls = container.locator('button, [role="button"]');
    const count = await controls.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const control = controls.nth(index);
      if (!(await control.isVisible().catch(() => false))) continue;
      const label = [
        await control.getAttribute('aria-label').catch(() => ''),
        await control.getAttribute('title').catch(() => ''),
        await control.innerText().catch(() => '')
      ].join(' ').toLowerCase();
      if (!/(?:next|следующ|далее|впер[её]д)/.test(label)) continue;
      if (await control.isDisabled().catch(() => false)) return false;
      if ((await control.getAttribute('aria-disabled').catch(() => '')) === 'true') return false;
      if (!(await control.click({ timeout: 5_000 }).then(() => true).catch(() => false))) continue;
      // Wait for the first donor cell to change; a short wait avoids treating
      // a re-rendered first page as a second page.
      for (let attempt = 0; attempt < 20; attempt += 1) {
        await page.waitForTimeout(250);
        const current = await readDonors(table);
        if (current.length && current[0].site !== previousFirstSite) return true;
      }
      return false;
    }
    container = container.locator('xpath=..');
  }
  return false;
}

async function collectTopLinkingSites(page) {
  const table = await waitForFirstVisible(page.locator('table, [role="table"], [role="grid"]'), 20_000)
    ? await topLinkingSitesTable(page)
    : null;
  if (!table) throw new Error('The Top linking sites table did not appear in Google Search Console.');
  const all = new Map();
  for (let pageNumber = 0; pageNumber < 100; pageNumber += 1) {
    const donors = await readDonors(table);
    if (!donors.length) throw new Error('The Top linking sites table did not contain donor domains.');
    for (const donor of donors) all.set(donor.site.toLowerCase(), donor);
    const advanced = await nextTablePage(page, table, donors[0].site);
    if (!advanced) break;
    await writeStatus('reading-table', `Reading Top linking sites table: ${all.size} donor domains collected.`, { donors: all.size });
  }
  return [...all.values()];
}

let browser;
let page;
try {
  await writeStatus('connecting', 'Connecting to local ShareSpider Chrome.');
  const chromium = await loadChromium();
  browser = await chromium.connectOverCDP(cdpURL, { timeout: 15_000 });
  const context = browser.contexts()[0];
  if (!context) fail('The managed Chrome profile is unavailable.');

  // Never take over a tab belonging to Page Indexing or Core Web Vitals.
  // Closing/redirecting that shared tab was the source of intermittent
  // "Target page, context or browser has been closed" failures.
  page = await context.newPage();
  const resource = encodeURIComponent(target);
  // domcontentloaded can fire before the GSC app paints. Give the report a
  // generous settle window; the interaction checks below handle the rest.
  await page.goto(`https://search.google.com/search-console/links?resource_id=${resource}`, { waitUntil: 'domcontentloaded', timeout: 45_000 });
  await page.waitForTimeout(6_000);

  const pageText = await page.locator('body').innerText().catch(() => '');
  if (/sign in|войти|choose an account|выберите аккаунт/i.test(pageText)) {
    await writeStatus('needs-sign-in', 'Sign in to Google Search Console in the ShareSpider Chrome window. ShareSpider is waiting and will continue automatically.');
    fail('Google sign-in is required in the ShareSpider Chrome window.');
  }
  if (/oops[,!]?\s*you (?:don't|do not) have access to this property|нет доступа к этому ресурсу|нет доступа к этому объекту/i.test(pageText)) {
    await writeStatus('access-denied', await snapshot(page, 'Google Search Console access denied for this property.'));
    fail('Google Search Console access denied for this property.');
  }

  // GSC may need to pick the property if the resource_id did not resolve to
  // the Links report (e.g. a bare domain passed where GSC expects sc-domain:).
  if (!/top linking sites|ссылающ|домены/i.test(pageText) && !(await firstVisible(page.getByRole('button', { name: /export|экспорт/i })))) {
    await writeStatus('diagnostic', await snapshot(page, 'The Links report did not open automatically. Check the property picker in the ShareSpider Chrome window; if the wrong property is selected, pick yours and retry.'));
  }

  await writeStatus('opening-donors', 'Opening Top linking sites in Google Search Console.');
  const openedDonors = await openTopLinkingSites(page);
  if (openedDonors === 'access-denied') {
    await writeStatus('access-denied', await snapshot(page, 'Google Search Console access denied for this property. Stopping without further retries.'));
    fail('Google Search Console access denied for this property.');
  }
  if (openedDonors !== true) {
    await writeStatus('export-unavailable', await snapshot(page, 'The Top linking sites “More” action was not found. Open that report once in the ShareSpider Chrome window, then retry.'));
    fail('The Google Search Console Top linking sites action was not found.');
  }

  await writeStatus('reading-table', 'Reading Top linking sites directly from the Google Search Console table.');
  const donors = await collectTopLinkingSites(page);
  const csv = [
    'Site,Linking pages,Target pages',
    ...donors.map(donor => `${csvField(donor.site)},${csvField(donor.linkingPages)},${csvField(donor.targetPages)}`)
  ].join('\n');
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, csv, 'utf8');
  await writeStatus('completed', `Google Search Console Links table imported: ${donors.length} donor domains.`, { output, donors: donors.length });
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  await writeStatus('failed', message).catch(() => {});
  fail(message);
} finally {
  // Disconnecting does not stop the user's Chrome. Only the temporary tab
  // created above is disposed, including when GSC has changed its UI.
  await page?.close().catch(() => {});
  await browser?.close().catch(() => {});
}
