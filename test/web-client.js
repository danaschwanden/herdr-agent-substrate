// Drive the hub's web terminal (ttyd) with a real browser, as a person would.
//
//   node test/web-client.js URL SCRIPT.json
//
// SCRIPT is a list of steps, run in order:
//   {"wait": "text", "timeout": 30}   until the screen shows text
//   {"keys": ["Control+b", "w"]}      key presses (Playwright key names)
//   {"type": "echo hi"}               typed text
//   {"sleep": 1}
// Prints one JSON line per step, {"step": i, "ok": bool, "ms": n}, and the
// final screen on failure. Reads the screen from xterm.js's buffer
// (ttyd exposes the terminal as window.term), not from pixels.
const { chromium } = require('playwright');
const fs = require('fs');

const [url, scriptPath] = process.argv.slice(2);
const script = JSON.parse(fs.readFileSync(scriptPath, 'utf8'));

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const screen = () => page.evaluate(() => {
    const b = window.term.buffer.active;
    const lines = [];
    for (let i = 0; i < window.term.rows; i++) {
      const line = b.getLine(b.viewportY + i);
      lines.push(line ? line.translateToString(true) : '');
    }
    return lines.join('\n');
  });
  let ok = true;
  try {
    await page.goto(url);
    await page.waitForFunction(() => window.term && window.term.rows > 0, null, { timeout: 15000 });
    await page.locator('.xterm').click();
    for (const [i, s] of script.entries()) {
      const t0 = Date.now();
      let good = true;
      if (s.wait !== undefined) {
        const deadline = t0 + (s.timeout || 30) * 1000;
        while (!(await screen()).includes(s.wait)) {
          if (Date.now() > deadline) { good = false; break; }
          await page.waitForTimeout(250);
        }
      } else if (s.keys) {
        for (const k of s.keys) { await page.keyboard.press(k); await page.waitForTimeout(400); }
      } else if (s.type !== undefined) {
        await page.keyboard.type(s.type, { delay: 20 });
      } else if (s.sleep) {
        await page.waitForTimeout(s.sleep * 1000);
      }
      console.log(JSON.stringify({ step: i, ok: good, ms: Date.now() - t0, ...s }));
      if (!good) { ok = false; break; }
    }
    if (process.env.WEB_SCREENSHOT) await page.screenshot({ path: process.env.WEB_SCREENSHOT });
  } catch (e) {
    console.log(JSON.stringify({ error: String(e) }));
    ok = false;
  }
  if (!ok) {
    try { console.log('--- screen\n' + await screen()); } catch (e) { /* page gone */ }
  }
  await browser.close();
  process.exit(ok ? 0 : 1);
})();
