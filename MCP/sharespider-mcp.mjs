#!/usr/bin/env node
// Local stdio MCP bridge for the native ShareSpider app. It never touches the
// browser UI: commands are delivered through the app's registered URL scheme.
import { createInterface } from 'node:readline';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const exec = promisify(execFile);
const appPath = '/Applications/ShareSpider.app';
const dataDirectory = join(homedir(), 'Library', 'Application Support', 'ShareSpider');
const pendingImport = join(dataDirectory, 'pending-project-import.txt');
const pendingCommand = join(dataDirectory, 'pending-command.txt');
const pendingBacklinkRules = join(dataDirectory, 'pending-backlink-classification-rules.json');
const pendingGSCBacklinks = join(dataDirectory, 'pending-gsc-backlinks.csv');
const pendingGSCSiteReport = join(dataDirectory, 'pending-gsc-site-report.csv');
const batchStatus = join(dataDirectory, 'batch-status.json');
const performanceLog = join(dataDirectory, 'performance-log.jsonl');
const projectsFile = join(dataDirectory, 'projects-journal.json');

function result(text) { return { content: [{ type: 'text', text }] }; }
function toolError(message) { return { content: [{ type: 'text', text: message }], isError: true }; }
function appURL(command, values = {}) {
  const url = new URL(`sharespider://${command}`);
  for (const [key, value] of Object.entries(values)) if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
  return url.href;
}
async function openApp(url) {
  if (!existsSync(appPath)) throw new Error('ShareSpider.app is not installed in /Applications.');
  mkdirSync(dataDirectory, { recursive: true });
  writeFileSync(pendingCommand, url, 'utf8');
  const running = await isAppRunning();
  // Launch only when ShareSpider is not already running. Calling `open -a`
  // repeatedly can create an additional SwiftUI window for the same process.
  if (!running) {
    await exec('/usr/bin/open', ['-g', '-a', appPath]);
    return; // the app consumes the pending command after it is ready
  }
  // Do not open the custom URL when the app is already running. macOS treats
  // that as a new document/window request for a SwiftUI WindowGroup. The
  // native app polls pending-command.txt once a second, so the file queue is
  // both reliable and keeps a single ShareSpider window.
  return;
}
async function isAppRunning() {
  try { await exec('/usr/bin/pgrep', ['-x', 'ShareSpider']); return true; }
  catch { return false; }
}
function parseJSON(path, fallback) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return fallback; }
}
function requireURLs(values) {
  const urls = Array.isArray(values.urls) ? values.urls : [];
  const valid = urls.map(String).map((value) => value.trim()).filter((value) => /^https?:\/\/.+/i.test(value));
  if (!valid.length) throw new Error('Provide one or more absolute http(s) URLs.');
  return valid;
}

const tools = [
  {
    name: 'sharespider_open',
    description: 'Open the native ShareSpider application without starting a crawl.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_run_batch',
    description: 'Start a native ShareSpider batch crawl without using the UI. Individual PDFs and one final critical-issues summary PDF are saved to Downloads/ShareSpider Reports.',
    inputSchema: { type: 'object', properties: {
      urls: { type: 'array', items: { type: 'string' }, description: 'Absolute site URLs.' },
      report: { type: 'string', enum: ['Client audit', 'Technical tasks', 'Both reports'], description: 'PDFs for each site. Default: Both reports.' },
      severity: { type: 'string', enum: ['High', 'High + Medium', 'All'], description: 'Technical-task priority. Default: High + Medium.' },
      concurrency: { type: 'integer', minimum: 1, maximum: 32 },
      maxURLs: { type: 'integer', minimum: 1, maximum: 50000 },
      searchConsole: { type: 'boolean', description: 'Use the connected Google Search Console account and store the resulting GSC totals in each project journal column. Default: enabled when an account is connected; pass false to skip.' }
    }, required: ['urls'] }
  },
  {
    name: 'sharespider_scan_site',
    description: 'Open ShareSpider and start a single-site crawl with optional crawl settings.',
    inputSchema: { type: 'object', properties: {
      url: { type: 'string', description: 'Absolute site URL.' }, concurrency: { type: 'integer', minimum: 1, maximum: 32 }, depth: { type: 'integer', minimum: 0, maximum: 30 }, testMode: { type: 'boolean', description: 'Ignore robots and nofollow for an authorised test crawl.' }
      , searchConsole: { type: 'boolean', description: 'After the crawl, inspect eligible page URLs in the connected Google Search Console property. Requires one-time OAuth connection in Settings → Integrations.' }
      , audit: { type: 'boolean', description: 'Run the technical audit automatically after the crawl, using the parsed HTML of the active crawl.' }
    }, required: ['url'] }
  },
  {
    name: 'sharespider_fetch_search_console',
    description: 'Fetch Google Search Console URL Inspection data for the current native ShareSpider crawl without recrawling the website. If a crawl is still running, the inspection is queued until it completes.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_connect_search_console',
    description: 'Connect the native ShareSpider app to Google Search Console. The OAuth token is stored locally by the app; macOS Keychain is not used.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_run_audit',
    description: 'Run the technical Audit for the current native ShareSpider crawl without opening another window. If needed, the latest saved crawl is restored.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_refresh_backlinks',
    description: 'Fetch or refresh DataForSEO backlink metrics for the current ShareSpider crawl. This runs independently of the site crawl and uses a seven-day local cache unless refresh is true.',
    inputSchema: { type: 'object', properties: { refresh: { type: 'boolean', description: 'Ignore the local seven-day cache and request fresh DataForSEO data.' } } }
  },
  {
    name: 'sharespider_append_backlink_classification_rules',
    description: 'Add donor and anchor phrases to ShareSpider backlink classification lists. Supported categories: web20, pbn, catalog, profile, crowd, article, spam, navigation. Rules are appended locally and immediately used for donor / anchor classification.',
    inputSchema: { type: 'object', properties: {
      rules: {
        type: 'object',
        description: 'Object where each supported category maps to an array of domains, URLs, paths or text phrases. Example: {"catalog":["example-directory.com"],"navigation":["visit website"]}.',
        additionalProperties: { type: 'array', items: { type: 'string' } }
      }
    }, required: ['rules'] }
  },
  {
    name: 'sharespider_import_gsc_backlink_export',
    description: 'Import a CSV exported from Google Search Console Links report (“Top linking sites” or “More sample links”) and compare its donor domains with active DataForSEO backlinks. This never replaces DataForSEO active/lost data.',
    inputSchema: { type: 'object', properties: {
      csvPath: { type: 'string', description: 'Absolute path to the Google Search Console Links CSV export.' }
    }, required: ['csvPath'] }
  },
  {
    name: 'sharespider_sync_gsc_backlinks_via_chrome',
    description: 'Use the local ShareSpider Chrome profile and Playwright to export the Google Search Console Links report, then compare its referring domains with active DataForSEO backlinks. The first run may require a one-time Google sign-in in that separate local Chrome profile.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_sync_gsc_page_indexing_via_chrome',
    description: 'Use the local ShareSpider Chrome profile and Playwright to automatically export the Google Search Console Page Indexing report. Results are kept separately from URL Inspection and preserve the last successful report if a new Chrome import fails.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_import_gsc_site_report',
    description: 'Import a CSV exported from Google Search Console Page indexing or mobile usability report. It is saved as a separate whole-site GSC block and never replaces URL Inspection API results.',
    inputSchema: { type: 'object', properties: { csvPath: { type: 'string', description: 'Absolute path to the GSC CSV export.' } }, required: ['csvPath'] }
  },
  {
    name: 'sharespider_get_audit_status',
    description: 'Read the current or most recently completed technical Audit summary, including hreflang reciprocal-link results.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_import_projects',
    description: 'Bulk-import named projects into ShareSpider. Each line must be “Name https://example.com”. Existing URLs are skipped.',
    inputSchema: { type: 'object', properties: { projects: { type: 'string', description: 'Newline-delimited name and absolute URL pairs.' } }, required: ['projects'] }
  },
  {
    name: 'sharespider_get_batch_status',
    description: 'Read the latest native ShareSpider batch progress and final summary report path.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_get_batch_result',
    description: 'Return report file paths for the most recently completed ShareSpider batch, ready to share in the chat.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'sharespider_get_performance_log',
    description: 'Read recent timings for crawl, issue calculation, audit and PDF creation.',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', minimum: 1, maximum: 500 } } }
  },
  {
    name: 'sharespider_list_projects',
    description: 'List locally saved ShareSpider projects and their latest issue totals.',
    inputSchema: { type: 'object', properties: {} }
  }
];

async function callTool(name, args = {}) {
  if (name === 'sharespider_open') {
    if (!existsSync(appPath)) throw new Error('ShareSpider.app is not installed in /Applications.');
    if (await isAppRunning()) return result('ShareSpider is already open.');
    await exec('/usr/bin/open', ['-g', '-a', appPath]);
    return result('Opened native ShareSpider.');
  }
  if (name === 'sharespider_run_batch') {
    const urls = requireURLs(args);
    await openApp(appURL('batch', { urls: urls.join('\n'), report: args.report ?? 'Both reports', severity: args.severity ?? 'High + Medium', concurrency: args.concurrency, maxURLs: args.maxURLs, searchConsole: args.searchConsole === false ? 0 : undefined }));
    return result(`Started native ShareSpider batch for ${urls.length} site(s). Search Console data will be included when the native account is connected (pass searchConsole: false to skip). Use sharespider_get_batch_status to track progress.`);
  }
  if (name === 'sharespider_scan_site') {
    const url = String(args.url ?? '').trim();
    if (!/^https?:\/\/.+/i.test(url)) throw new Error('Provide an absolute http(s) URL.');
    await openApp(appURL('scan', { url, concurrency: args.concurrency, depth: args.depth, testMode: args.testMode ? 1 : undefined, searchConsole: args.searchConsole ? 1 : undefined, audit: args.audit ? 1 : undefined, start: 1 }));
    return result(`Started native ShareSpider crawl: ${url}${args.searchConsole ? ' · Search Console inspection queued after crawl' : ''}${args.audit ? ' · technical audit queued after crawl' : ''}`);
  }
  if (name === 'sharespider_fetch_search_console') {
    await openApp(appURL('search-console', { start: 1 }));
    return result('Sent Search Console inspection request to native ShareSpider. It will use the current crawl results and will not recrawl the site.');
  }
  if (name === 'sharespider_connect_search_console') {
    await openApp(appURL('connect-search-console', { start: 1 }));
    return result('Started the native Search Console connection flow. It uses the browser Google session and saves the refresh token locally in ShareSpider.');
  }
  if (name === 'sharespider_run_audit') {
    await openApp(appURL('audit', { start: 1 }));
    return result('Sent technical Audit request to native ShareSpider. Use sharespider_get_audit_status for the result.');
  }
  if (name === 'sharespider_refresh_backlinks') {
    await openApp(appURL('backlinks', { refresh: args.refresh === false ? 0 : 1 }));
    return result('Sent DataForSEO backlink analysis request to native ShareSpider. It runs after any active crawl and uses the configured local DataForSEO credentials.');
  }
  if (name === 'sharespider_append_backlink_classification_rules') {
    const allowed = new Set(['web20', 'pbn', 'catalog', 'profile', 'crowd', 'article', 'spam', 'navigation']);
    const input = args.rules && typeof args.rules === 'object' ? args.rules : {};
    const cleaned = Object.fromEntries(
      Object.entries(input)
        .filter(([key, values]) => allowed.has(key) && Array.isArray(values))
        .map(([key, values]) => [key, [...new Set(values.map(String).map(value => value.trim()).filter(Boolean))]])
        .filter(([, values]) => values.length)
    );
    if (!Object.keys(cleaned).length) throw new Error('Provide at least one non-empty supported rule category.');
    mkdirSync(dataDirectory, { recursive: true });
    writeFileSync(pendingBacklinkRules, JSON.stringify(cleaned, null, 2), 'utf8');
    await openApp(appURL('backlink-rules', { start: 1 }));
    const count = Object.values(cleaned).reduce((total, values) => total + values.length, 0);
    return result(`Queued ${count} backlink classification phrase(s) in ${Object.keys(cleaned).join(', ')}. ShareSpider will store them locally and apply them to the Backlinks tab.`);
  }
  if (name === 'sharespider_import_gsc_backlink_export') {
    const csvPath = String(args.csvPath ?? '').trim();
    if (!csvPath || !existsSync(csvPath)) throw new Error('The specified Google Search Console CSV file does not exist.');
    const csv = readFileSync(csvPath, 'utf8');
    if (!csv.trim()) throw new Error('The specified Google Search Console CSV is empty.');
    mkdirSync(dataDirectory, { recursive: true });
    writeFileSync(pendingGSCBacklinks, csv, 'utf8');
    await openApp(appURL('gsc-backlinks-import', { start: 1 }));
    return result('Queued the Google Search Console Links export. ShareSpider will compare its donors with active DataForSEO donors without replacing the DataForSEO dataset.');
  }
  if (name === 'sharespider_sync_gsc_backlinks_via_chrome') {
    await openApp(appURL('gsc-chrome-links-sync', { start: 1 }));
    return result('Started ShareSpider Chrome / Playwright export for the Google Search Console Links report. If this is the first run, sign in to Google in the dedicated ShareSpider Chrome profile, then run this tool once more.');
  }
  if (name === 'sharespider_sync_gsc_page_indexing_via_chrome') {
    await openApp(appURL('gsc-chrome-page-indexing-sync', { start: 1 }));
    return result('Started ShareSpider Chrome / Playwright export for the Google Search Console Page Indexing report. The first run may require a one-time Google sign-in in the dedicated ShareSpider Chrome profile.');
  }
  if (name === 'sharespider_import_gsc_site_report') {
    const csvPath = String(args.csvPath ?? '').trim();
    if (!csvPath || !existsSync(csvPath)) throw new Error('The specified Google Search Console CSV file does not exist.');
    const csv = readFileSync(csvPath, 'utf8');
    if (!csv.trim()) throw new Error('The specified Google Search Console CSV is empty.');
    mkdirSync(dataDirectory, { recursive: true });
    writeFileSync(pendingGSCSiteReport, csv, 'utf8');
    await openApp(appURL('gsc-site-report-import', { start: 1 }));
    return result('Queued the GSC site-wide Page indexing report. ShareSpider will show it as a separate Overview, Audit and project-journal block.');
  }
  if (name === 'sharespider_get_audit_status') {
    const status = parseJSON(join(dataDirectory, 'audit-status.json'), null);
    return result(status ? JSON.stringify(status, null, 2) : 'No ShareSpider audit status has been recorded yet.');
  }
  if (name === 'sharespider_import_projects') {
    const projects = String(args.projects ?? '').trim();
    if (!projects) throw new Error('Provide one or more project lines.');
    mkdirSync(dataDirectory, { recursive: true });
    writeFileSync(pendingImport, projects, 'utf8');
    await openApp(appURL('projects/import'));
    return result('Project import was sent to native ShareSpider. Existing URLs will be skipped.');
  }
  if (name === 'sharespider_get_batch_status') {
    const status = parseJSON(batchStatus, null);
    return result(status ? JSON.stringify(status, null, 2) : 'No ShareSpider batch status has been recorded yet.');
  }
  if (name === 'sharespider_get_batch_result') {
    const status = parseJSON(batchStatus, null);
    if (!status || status.currentSite !== 'Batch complete') return result('The latest batch is still running.');
    const reports = Array.isArray(status.reportPaths) ? status.reportPaths : (status.summaryReportPath ? [status.summaryReportPath] : []);
    return result(reports.length ? reports.join('\n') : 'The batch completed but did not create report files.');
  }
  if (name === 'sharespider_get_performance_log') {
    const limit = Math.max(1, Math.min(500, Number(args.limit ?? 100)));
    try { return result(readFileSync(performanceLog, 'utf8').trim().split('\n').slice(-limit).join('\n') || 'No timings recorded yet.'); }
    catch { return result('No timings recorded yet.'); }
  }
  if (name === 'sharespider_list_projects') {
    const projects = parseJSON(projectsFile, []);
    const view = projects.map((project) => ({ name: project.name, url: project.startURL, type: project.kind, latestIssueTotal: (project.runs?.at(-1)?.errors ? Object.values(project.runs.at(-1).errors).reduce((sum, value) => sum + Number(value || 0), 0) : 0) }));
    return result(JSON.stringify(view, null, 2));
  }
  throw new Error(`Unknown tool: ${name}`);
}

function send(message) { process.stdout.write(`${JSON.stringify(message)}\n`); }
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', async (line) => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  if (request.method === 'notifications/initialized') return;
  try {
    if (request.method === 'initialize') {
      send({ jsonrpc: '2.0', id: request.id, result: { protocolVersion: request.params?.protocolVersion ?? '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'ShareSpider', version: '1.0.0' } } });
    } else if (request.method === 'tools/list') {
      send({ jsonrpc: '2.0', id: request.id, result: { tools } });
    } else if (request.method === 'tools/call') {
      const output = await callTool(request.params?.name, request.params?.arguments);
      send({ jsonrpc: '2.0', id: request.id, result: output });
    } else {
      send({ jsonrpc: '2.0', id: request.id, error: { code: -32601, message: 'Method not found' } });
    }
  } catch (error) {
    send({ jsonrpc: '2.0', id: request.id, result: toolError(error instanceof Error ? error.message : String(error)) });
  }
});
