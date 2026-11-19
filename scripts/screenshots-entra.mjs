// Captures the screenshots used in entra-id/README.md into docs/screenshots/entra/.
// Needs the UI port-forward running (see scripts/screenshots.mjs) and:
//   TENANT_ID, APP_ID   the values from the Entra ID guide
// Usage: TENANT_ID=... APP_ID=... node scripts/screenshots-entra.mjs
import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';

const base = process.env.UI_URL ?? 'http://localhost:15000';
const { TENANT_ID, APP_ID } = process.env;
const outDir = new URL('../docs/screenshots/entra/', import.meta.url).pathname;
await mkdir(outDir, { recursive: true });

const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  colorScheme: 'dark',
});
const page = await context.newPage();

// Blur anything that looks like an email address or a GUID so screenshots can be shared.
async function redact() {
  await page.evaluate(() => {
    const re = /[\w.+-]+@[\w-]+\.[\w.]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{0,12}/i;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const hits = [];
    while (walker.nextNode()) if (re.test(walker.currentNode.nodeValue)) hits.push(walker.currentNode.parentElement);
    for (const el of hits) el.style.filter = 'blur(6px)';
  });
}

// 1. The Microsoft sign-in page Codex sends you to.
if (TENANT_ID && APP_ID) {
  const q = new URLSearchParams({
    response_type: 'code', client_id: APP_ID, redirect_uri: 'http://127.0.0.1:1455/callback',
    code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', code_challenge_method: 'S256',
    state: 'screenshot', scope: `api://${APP_ID}/access offline_access`,
  });
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 1100, height: 760 });
  await page.goto(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/authorize?${q}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${outDir}signin.png` });
  console.log('saved signin.png');
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.setViewportSize({ width: 1440, height: 900 });
}

// 2. Logs list, then the newest entry expanded (user, group, prompt and completion).
await page.goto(`${base}/ui/llm/logs`, { waitUntil: 'networkidle' });
await page.waitForTimeout(1500);
await redact();
await page.screenshot({ path: `${outDir}logs-users.png` });
console.log('saved logs-users.png');

await page.locator('tbody tr').first().click();
await page.waitForTimeout(2000);
const convo = page.locator('details.log-conversation > summary').first();
if (await convo.count()) { await convo.click(); await page.waitForTimeout(800); }
await redact();
await page.screenshot({ path: `${outDir}log-detail.png`, fullPage: false });
console.log('saved log-detail.png');

await browser.close();
