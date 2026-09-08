// Renders brand/src/*.html to PNG with Playwright (uses the installed Chrome, no browser download).
//   cd brand && npm i && npm run render
import { chromium } from "playwright-core";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = (f) => pathToFileURL(path.join(here, "src", f)).href;
const out = (f) => path.join(here, f);

const jobs = [
  { file: "profile.html", w: 800, h: 800, png: "profile.png" },
  { file: "profile.html", w: 800, h: 800, png: "profile-dark.png", bodyClass: "dark" },
  { file: "banner.html", w: 1500, h: 500, png: "banner.png" },
  { file: "favicon.html", w: 512, h: 512, png: "favicon.png", transparent: true },
  ...["cover", "week", "auction", "loop"].map((n) => ({ file: "article/" + n + ".html", w: 1600, h: 900, png: "article/" + n + ".png" })),
];

const browser = await chromium.launch({ channel: "chrome" });
try {
  for (const j of jobs) {
    const page = await browser.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await page.goto(src(j.file));
    if (j.bodyClass) await page.evaluate((c) => document.body.classList.add(c), j.bodyClass);
    await page.evaluate(() => document.fonts.load('800 62px "Schibsted Grotesk"').then(() => document.fonts.ready));
    const fonts = await page.evaluate(() => document.fonts.check('800 62px "Schibsted Grotesk"'));
    if (!fonts) throw new Error(`Schibsted Grotesk did not load for ${j.file}`);
    await page.screenshot({ path: out(j.png), type: "png", omitBackground: !!j.transparent, clip: { x: 0, y: 0, width: j.w, height: j.h } });
    console.log("wrote", j.png);
    await page.close();
  }
} finally {
  await browser.close();
}
