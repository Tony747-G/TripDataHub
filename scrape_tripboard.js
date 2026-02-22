const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { chromium } = require('playwright');

const START_URL = 'https://tripboard.bidproplus.com/';
const OUT_DIR = path.join(process.cwd(), 'output');
const STORAGE_STATE = path.join(process.cwd(), 'storageState.json');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function normalizeSpace(text) {
  return (text || '').replace(/\s+/g, ' ').trim();
}

function toSlug(text) {
  return normalizeSpace(text)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/(^-|-$)/g, '') || 'section';
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(question, (answer) => {
    rl.close();
    resolve(answer);
  }));
}

async function scrapeVisibleData(page, label) {
  const payload = await page.evaluate((inputLabel) => {
    const pickTexts = (nodes, limit = 200) => {
      const out = [];
      for (const node of nodes) {
        const text = (node?.innerText || node?.textContent || '').replace(/\s+/g, ' ').trim();
        if (!text) continue;
        out.push(text);
        if (out.length >= limit) break;
      }
      return out;
    };

    const tables = Array.from(document.querySelectorAll('table')).map((table, i) => {
      const headers = Array.from(table.querySelectorAll('th')).map((x) => (x.innerText || '').replace(/\s+/g, ' ').trim()).filter(Boolean);
      const rows = Array.from(table.querySelectorAll('tr')).map((tr) =>
        Array.from(tr.querySelectorAll('th,td')).map((x) => (x.innerText || '').replace(/\s+/g, ' ').trim()).filter(Boolean)
      ).filter((row) => row.length > 0);
      return { index: i, headers, rows };
    }).filter((t) => t.rows.length > 0);

    const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,[role="heading"],.title,.header,.panel-title'));
    const sections = headings.map((h) => {
      const heading = (h.innerText || '').replace(/\s+/g, ' ').trim();
      if (!heading) return null;
      const container = h.closest('section,article,.card,.panel,.container,div') || h.parentElement;
      if (!container) return null;
      const text = (container.innerText || '').replace(/\s+/g, ' ').trim();
      return {
        heading,
        text: text.slice(0, 4000),
      };
    }).filter(Boolean);

    const scheduleKeywords = /schedule|pairing|trip|roster|line/i;
    const openKeywords = /open\s*time|opentime|open\s*trip|open trips|pickup|open/i;

    const allBlocks = pickTexts(document.querySelectorAll('main,section,article,div,li,tr'));
    const scheduleBlocks = allBlocks.filter((t) => scheduleKeywords.test(t)).slice(0, 80);
    const openTimeBlocks = allBlocks.filter((t) => openKeywords.test(t)).slice(0, 80);

    return {
      label: inputLabel,
      title: document.title,
      url: window.location.href,
      capturedAt: new Date().toISOString(),
      tables,
      sections,
      scheduleBlocks,
      openTimeBlocks,
      bodyTextSnippet: (document.body?.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 12000),
    };
  }, label);

  const html = await page.content();
  const slug = toSlug(label);
  fs.writeFileSync(path.join(OUT_DIR, `${slug}.html`), html, 'utf8');
  fs.writeFileSync(path.join(OUT_DIR, `${slug}.json`), JSON.stringify(payload, null, 2), 'utf8');
  return payload;
}

async function tryClick(page, selectors, timeout = 3000) {
  for (const selector of selectors) {
    const locator = page.locator(selector).first();
    try {
      if (await locator.count()) {
        await locator.click({ timeout });
        await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
        await page.waitForTimeout(1000);
        return selector;
      }
    } catch {
      // keep trying
    }
  }
  return null;
}

async function main() {
  ensureDir(OUT_DIR);

  const responses = [];
  const context = await chromium.launchPersistentContext(path.join(process.cwd(), '.pw-user-data'), {
    headless: false,
    viewport: { width: 1440, height: 900 },
  });

  if (fs.existsSync(STORAGE_STATE)) {
    try {
      await context.addCookies(JSON.parse(fs.readFileSync(STORAGE_STATE, 'utf8')).cookies || []);
    } catch {
      // ignore invalid saved state
    }
  }

  context.on('response', async (resp) => {
    const url = resp.url();
    const type = resp.request().resourceType();
    if (!['xhr', 'fetch'].includes(type)) return;
    if (!/trip|schedule|open|pair|crew|bid|line/i.test(url)) return;

    const entry = {
      url,
      status: resp.status(),
      contentType: resp.headers()['content-type'] || '',
    };

    try {
      const ct = entry.contentType.toLowerCase();
      if (ct.includes('application/json')) {
        entry.json = await resp.json();
      } else {
        const text = await resp.text();
        entry.textSnippet = text.slice(0, 2000);
      }
    } catch {
      // ignore unreadable responses
    }

    responses.push(entry);
  });

  const page = context.pages()[0] || await context.newPage();
  await page.goto(START_URL, { waitUntil: 'domcontentloaded', timeout: 90000 });
  await page.waitForTimeout(3000);

  const needsLogin = /login|signin|auth|sso/i.test(page.url()) || /sign in|log in/i.test(await page.content());
  if (needsLogin) {
    console.log('\nLogin required in the opened browser window.');
    console.log('After login is complete and your schedule is visible, press Enter here.\n');
    await ask('Press Enter to continue... ');
  }

  await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(1500);

  const snapshots = [];
  snapshots.push(await scrapeVisibleData(page, 'current-view'));

  const clickedSchedule = await tryClick(page, [
    'a:has-text("Schedule")',
    'button:has-text("Schedule")',
    '[role="tab"]:has-text("Schedule")',
    'a:has-text("My Schedule")',
    'button:has-text("My Schedule")',
  ]);
  if (clickedSchedule) {
    snapshots.push(await scrapeVisibleData(page, 'schedule-view'));
  }

  const clickedOpenTime = await tryClick(page, [
    'a:has-text("Open Time")',
    'button:has-text("Open Time")',
    '[role="tab"]:has-text("Open Time")',
    'a:has-text("Open")',
    'button:has-text("Open")',
    '[role="tab"]:has-text("Open")',
  ]);
  if (clickedOpenTime) {
    snapshots.push(await scrapeVisibleData(page, 'open-time-view'));
  }

  const storage = await context.storageState();
  fs.writeFileSync(STORAGE_STATE, JSON.stringify(storage, null, 2), 'utf8');

  const output = {
    startedAt: new Date().toISOString(),
    currentUrl: page.url(),
    clickedSchedule,
    clickedOpenTime,
    snapshots,
    capturedApiResponses: responses,
  };

  fs.writeFileSync(path.join(OUT_DIR, 'tripboard_scrape.json'), JSON.stringify(output, null, 2), 'utf8');

  const concise = {
    url: output.currentUrl,
    scheduleHighlights: snapshots.flatMap((s) => s.scheduleBlocks || []).slice(0, 50),
    openTimeHighlights: snapshots.flatMap((s) => s.openTimeBlocks || []).slice(0, 50),
    tableCount: snapshots.reduce((acc, s) => acc + (s.tables?.length || 0), 0),
    apiResponseCount: responses.length,
  };
  fs.writeFileSync(path.join(OUT_DIR, 'summary.json'), JSON.stringify(concise, null, 2), 'utf8');

  console.log(`Saved scrape output in: ${OUT_DIR}`);
  console.log(`- ${path.join(OUT_DIR, 'tripboard_scrape.json')}`);
  console.log(`- ${path.join(OUT_DIR, 'summary.json')}`);

  await context.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
