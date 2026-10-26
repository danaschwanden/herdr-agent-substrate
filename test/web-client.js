// Drive the hub's web terminal (ttyd) with a real browser, as a person would.
//
//   node test/web-client.js URL SCRIPT.json
//
// SCRIPT is a list of steps, run in order:
//   {"wait": "text", "timeout": 30}   until the screen shows text
//   {"keys": ["Control+b", "w"]}      key presses (Playwright key names)
//   {"type": "echo hi"}               typed text
//   {"sleep": 1}
//   {"drag": "text"}                  select text with the mouse (herdr's own
//                                     selection; the last line with it that
//                                     isn't the command echoing it)
//   {"rightclick": "text"}            right-click on that text
//   {"click": "text"}                 click the first line showing text (e.g. a
//                                     workspace in herdr's sidebar)
//   {"click": "text", "until": "t2"}  click again until the screen shows t2
//                                     and keeps showing it for 2 s
//   {"clipboard": "text"}             until the clipboard holds exactly this
//   {"setClipboard": "text"}
//   {"menuBlocked": true}             the browser's context menu was suppressed
// Prints one JSON line per step, {"step": i, "ok": bool, "ms": n}, and the
// final screen on failure. Reads the screen from xterm.js's buffer
// (ttyd exposes the terminal as window.term), not from pixels.
const { chromium } = require('playwright');
const fs = require('fs');

const [url, scriptPath] = process.argv.slice(2);
const script = JSON.parse(fs.readFileSync(scriptPath, 'utf8'));

(async () => {
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1400, height: 900 }, permissions: ['clipboard-read', 'clipboard-write'] });
  const page = await context.newPage();
  const screen = () => page.evaluate(() => {
    const b = window.term.buffer.active;
    const lines = [];
    for (let i = 0; i < window.term.rows; i++) {
      const line = b.getLine(b.viewportY + i);
      lines.push(line ? line.translateToString(true) : '');
    }
    return lines.join('\n');
  });
  // Cell geometry, and the screen position of the last line showing text.
  const locate = async (text, first) => {
    const geo = await page.evaluate(() => {
      const r = document.querySelector('.xterm-screen').getBoundingClientRect();
      return { x: r.x, y: r.y, cw: r.width / window.term.cols, ch: r.height / window.term.rows };
    });
    const lines = (await screen()).split('\n');
    let row = -1;
    lines.forEach((l, i) => {
      // first: any line (the sidebar shares rows with the pane); otherwise the
      // last line, skipping the command that echoed the text.
      if (first ? row < 0 && l.includes(text) : l.includes(text) && !l.includes('echo ')) row = i;
    });
    if (row < 0) throw new Error('not on screen: ' + text);
    const col = lines[row].indexOf(text);
    return { y: geo.y + (row + 0.5) * geo.ch, x0: geo.x + (col + 0.5) * geo.cw,
             x1: geo.x + (col + text.length - 0.5) * geo.cw };
  };
  const clipboard = () => page.evaluate(() => navigator.clipboard.readText());
  let ok = true;
  try {
    await page.goto(url);
    await page.waitForFunction(() => window.term && window.term.rows > 0, null, { timeout: 15000 });
    await page.evaluate(() => {
      window.__menus = [];
      window.addEventListener('contextmenu', (e) => window.__menus.push(e.defaultPrevented));
    });
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
      } else if (s.drag !== undefined) {
        const at = await locate(s.drag);
        await page.mouse.move(at.x0, at.y);
        await page.mouse.down();
        await page.mouse.move(at.x1, at.y, { steps: 8 });
        await page.mouse.up();
      } else if (s.click !== undefined) {
        // The sidebar redraws while connections come up: locate right
        // before each click, and with "until", click until the result holds.
        const deadline = t0 + (s.timeout || 30) * 1000;
        for (;;) {
          let at = null;
          try { at = await locate(s.click, true); } catch (e) {
            if (Date.now() > deadline) throw e;
          }
          if (at) await page.mouse.click(at.x0, at.y);
          if (s.until === undefined && at) break;
          if (at) {
            await page.waitForTimeout(500);
            let held = 0;
            while (held < 2000 && (await screen()).includes(s.until)) {
              await page.waitForTimeout(250);
              held += 250;
            }
            if (held >= 2000) break;
          }
          if (Date.now() > deadline) { good = false; break; }
          await page.waitForTimeout(250);
        }
      } else if (s.rightclick !== undefined) {
        const at = await locate(s.rightclick);
        await page.mouse.click(at.x0, at.y, { button: 'right' });
      } else if (s.setClipboard !== undefined) {
        await page.evaluate((t) => navigator.clipboard.writeText(t), s.setClipboard);
      } else if (s.clipboard !== undefined) {
        const deadline = t0 + (s.timeout || 5) * 1000;
        while ((await clipboard()) !== s.clipboard) {
          if (Date.now() > deadline) { good = false; break; }
          await page.waitForTimeout(100);
        }
      } else if (s.menuBlocked !== undefined) {
        const menus = await page.evaluate(() => window.__menus);
        good = menus.length > 0 && menus.every((m) => m === s.menuBlocked);
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
