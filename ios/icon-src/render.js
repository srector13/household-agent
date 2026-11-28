// Renders the eight app icons (4 marks × black/white tile) plus tinted variants and previews.
//   node ios/icon-src/render.js
// Writes SVG sources next to this script and PNGs into ../SecondBrain/Assets.xcassets.
// Uses the Chromium that ships with Playwright. No purple, on purpose (hue 232–335 is banned).
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const HERE = __dirname;
const ASSETS = path.join(HERE, '..', 'SecondBrain', 'Assets.xcassets');

// Each mark is drawn in a 100×100 box (G = the glyph paint). Geometry matches the mockups.
const MARKS = {
  caught: {
    name: 'Caught thought',
    body: '<path d="M75.6 47.5A26 26 0 1 1 54.5 26.4" fill="none" stroke="G" stroke-width="7" stroke-linecap="round"/>' +
          '<circle cx="50" cy="52" r="9" fill="G"/>',
  },
  minds: {
    name: 'Two minds',
    body: '<circle cx="39" cy="50" r="19" fill="none" stroke="G" stroke-width="7"/>' +
          '<circle cx="61" cy="50" r="19" fill="none" stroke="G" stroke-width="7"/>',
  },
  loop: {
    name: 'Loop',
    body: '<g transform="translate(0 3)"><path d="M78 50A28 28 0 0 0 22 50A22 22 0 0 0 66 50A16 16 0 0 0 34 50" ' +
          'fill="none" stroke="G" stroke-width="6.5" stroke-linecap="round"/><circle cx="34" cy="50" r="6.5" fill="G"/></g>',
  },
  orbit: {
    name: 'Orbit',
    body: '<circle cx="50" cy="51" r="24" fill="none" stroke="G" stroke-width="6.5"/>' +
          '<circle cx="67" cy="34" r="8.5" fill="G"/>',
  },
};

// Asset names: Caught on black is the primary icon.
const ICONS = [];
for (const key of Object.keys(MARKS)) {
  const cap = key[0].toUpperCase() + key.slice(1);
  ICONS.push({ key, tile: 'black', asset: key === 'caught' ? 'AppIcon' : `AppIcon-${cap}`, preview: `IconPreview-${cap}` });
  ICONS.push({ key, tile: 'white', asset: `AppIcon-${cap}Light`, preview: `IconPreview-${cap}Light` });
}

const SCALE = 0.95; // glyph size inside the tile (about the same visual weight as the old logo)

function svg(key, tile) {
  const m = MARKS[key];
  const tinted = tile === 'tinted';
  const ink = tile === 'black' ? ['#2E8BFF', '#2FE0D2'] : tile === 'white' ? ['#0A6CFF', '#0FB5A8'] : ['#FFFFFF', '#C8C8C8'];
  const bg = tile === 'black' ? '<rect width="100" height="100" fill="url(#bg)"/>'
    : tile === 'white' ? '<rect width="100" height="100" fill="url(#bg)"/>' : '';
  const bgStops = tile === 'black' ? ['#1C1C1E', '#000000'] : ['#FFFFFF', '#EDEDF2'];
  const body = m.body.replace(/"G"/g, '"url(#ink)"');
  const t = `translate(${50 - 50 * SCALE} ${50 - 50 * SCALE}) scale(${SCALE})`;
  // Black tiles get a soft glow; the filter region is the whole canvas so nothing clips.
  const glow = tile === 'black'
    ? `<filter id="glow" filterUnits="userSpaceOnUse" x="0" y="0" width="100" height="100"><feGaussianBlur stdDeviation="2.2"/></filter>` : '';
  const glowUse = tile === 'black' ? `<g transform="${t}" filter="url(#glow)" opacity=".45">${body}</g>` : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="100" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${bgStops[0]}"/><stop offset="1" stop-color="${bgStops[1]}"/></linearGradient>
    <linearGradient id="ink" x1="22" y1="78" x2="78" y2="22" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${ink[0]}"/><stop offset="1" stop-color="${ink[1]}"/></linearGradient>
    ${glow}
  </defs>
  ${tinted ? '' : bg}
  ${glowUse}
  <g transform="${t}">${body}</g>
</svg>
`;
}

function contents(withDark, files) {
  const images = [{ filename: files.any, idiom: 'universal', platform: 'ios', size: '1024x1024' }];
  if (withDark) images.push({ appearances: [{ appearance: 'luminosity', value: 'dark' }], filename: files.dark, idiom: 'universal', platform: 'ios', size: '1024x1024' });
  images.push({ appearances: [{ appearance: 'luminosity', value: 'tinted' }], filename: files.tinted, idiom: 'universal', platform: 'ios', size: '1024x1024' });
  return JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2) + '\n';
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  async function png(svgText, out, size, transparent) {
    await page.setViewportSize({ width: size, height: size });
    const s = svgText.replace('width="1024" height="1024"', `width="${size}" height="${size}"`);
    await page.setContent(`<html><body style="margin:0;background:${transparent ? 'transparent' : '#000'}">${s}</body></html>`);
    await page.screenshot({ path: out, omitBackground: transparent, clip: { x: 0, y: 0, width: size, height: size } });
  }
  for (const k of Object.keys(MARKS)) {
    for (const tile of ['black', 'white', 'tinted']) fs.writeFileSync(path.join(HERE, `${k}-${tile}.svg`), svg(k, tile));
  }
  for (const ic of ICONS) {
    const dir = path.join(ASSETS, `${ic.asset}.appiconset`);
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });
    const black = ic.tile === 'black';
    await png(svg(ic.key, ic.tile), path.join(dir, 'icon-1024.png'), 1024, false);
    if (black) await png(svg(ic.key, 'black'), path.join(dir, 'icon-1024-dark.png'), 1024, false);
    await png(svg(ic.key, 'tinted'), path.join(dir, 'icon-1024-tinted.png'), 1024, true);
    fs.writeFileSync(path.join(dir, 'Contents.json'),
      contents(black, { any: 'icon-1024.png', dark: 'icon-1024-dark.png', tinted: 'icon-1024-tinted.png' }));
    const pdir = path.join(ASSETS, `${ic.preview}.imageset`);
    fs.rmSync(pdir, { recursive: true, force: true });
    fs.mkdirSync(pdir, { recursive: true });
    await png(svg(ic.key, ic.tile), path.join(pdir, 'preview.png'), 240, false);
    fs.writeFileSync(path.join(pdir, 'Contents.json'),
      JSON.stringify({ images: [{ filename: 'preview.png', idiom: 'universal' }], info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
  }
  await browser.close();
  console.log(ICONS.map(i => i.asset).join(' '));
})();
