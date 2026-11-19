// Captures the agentgateway UI pages into docs/screenshots/.
// Needs the UI port-forward running:
//   kubectl -n agentgateway-system port-forward deploy/agentgateway-proxy 15000:15000
// Usage: npm run screenshots   (override the address with UI_URL=http://host:port)
import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';

const base = process.env.UI_URL ?? 'http://localhost:15000';
const outDir = new URL('../docs/screenshots/', import.meta.url).pathname;

const pages = [
  ['home', '/ui'],
  ['models', '/ui/llm/models'],
  ['routes', '/ui/traffic/routes'],
  ['logs', '/ui/llm/logs'],
  ['analytics', '/ui/llm/analytics'],
  ['costs', '/ui/llm/costs'],
];

await mkdir(outDir, { recursive: true });
const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  colorScheme: 'dark',
});
const page = await context.newPage();

for (const [name, path] of pages) {
  await page.goto(base + path, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500); // let charts and tables finish rendering
  await page.screenshot({ path: `${outDir}${name}.png`, fullPage: true });
  console.log(`saved docs/screenshots/${name}.png`);
}

await browser.close();
