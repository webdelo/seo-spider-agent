#!/usr/bin/env node
// Mobile-only Core Web Vitals export via the user-authorised Chrome profile.
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
const playwrightCorePath = process.env.SHARESPIDER_PLAYWRIGHT_CORE;
if (!playwrightCorePath) throw new Error('The bundled Playwright runtime is unavailable.');
const { chromium } = await import(playwrightCorePath);
const pairs = process.argv.slice(2); const arg = key => pairs[pairs.indexOf(key) + 1];
const target = arg('--target'); const output = resolve(arg('--output')); const status = resolve(arg('--status'));
const reportURL = `https://search.google.com/search-console/core-web-vitals?resource_id=${encodeURIComponent(new URL(target).origin + '/')}`;
const statusWrite = async (state, message) => { await mkdir(dirname(status), { recursive: true }); await writeFile(status, JSON.stringify({ state, message })); };
const csv = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
try {
  await rm(output, { force: true }); await statusWrite('running', 'Opening mobile Core Web Vitals');
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222'); const context = browser.contexts()[0];
  let page = context.pages().find(p => p.url().includes('search.google.com/search-console')) || await context.newPage();
  await page.goto(reportURL, { waitUntil: 'domcontentloaded', timeout: 60_000 }); await page.waitForTimeout(4_000);
  const body = await page.locator('body').innerText();
  if (/sign in|войти|вход в аккаунт/i.test(body)) throw new Error('Sign in to Google in the ShareSpider Chrome window, then retry.');
  if (/oops[,!]?\s*you (?:don't|do not) have access to this property|нет доступа к этому ресурсу|нет доступа к этому объекту/i.test(body)) throw new Error('Google Search Console access denied for this property. ShareSpider stopped the Chrome Core Web Vitals check.');
  await statusWrite('running', 'Reading mobile Poor and Needs improvement groups');
  const cards = await page.locator('button, [role="button"], a').evaluateAll(items => items.map(node => (node.innerText || '').replace(/\s+/g, ' ').trim()).filter(text => /poor|needs improvement|требует улучшения|низк/i.test(text)));
  const lines = ['Group,Issue,Pages,URL'];
  for (const card of cards) {
    const group = /poor|низк/i.test(card) ? 'Poor' : 'Needs improvement';
    const match = card.match(/(\d[\d\s,]*)/); const count = match ? match[1].replace(/[^0-9]/g, '') : '0';
    lines.push(`${csv(group)},${csv('Mobile Core Web Vitals')},${csv(count)},`);
  }
  // "Not enough usage data" is a valid GSC answer, not an import failure.
  // Leave a schema-correct empty report so ShareSpider can show that state
  // distinctly from Chrome/authorisation errors.
  await writeFile(output, lines.join('\n'));
  await statusWrite('completed', lines.length === 1
    ? 'Google reports no mobile Core Web Vitals field-data groups for this property.'
    : 'Mobile Core Web Vitals imported.');
  await browser.close();
} catch (error) { await statusWrite('failed', error.message || String(error)); console.error(error); process.exit(1); }
