// Drives the real YTM Glow app without YouTube Music: launches Chromium with
// the extension and a mock player that plays a synthetic 120 BPM beat while
// posing as a real song, so LRCLIB lyrics and album colors load for real.
//
//   node demo/demo.mjs                       # "Get Lucky" by Daft Punk, headless
//   node demo/demo.mjs --headed --seconds 60
//   node demo/demo.mjs --title "..." --artist "..." --duration 215 --seek 20 --art https://i.ytimg.com/vi/<id>/hqdefault.jpg
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { chromium } from 'playwright';

const { values } = parseArgs({
  options: {
    title: { type: 'string', default: 'Get Lucky' },
    artist: { type: 'string', default: 'Daft Punk' },
    album: { type: 'string', default: 'Random Access Memories' },
    duration: { type: 'string', default: '248' },
    seek: { type: 'string', default: '28' },
    art: { type: 'string', default: 'https://i.ytimg.com/vi/5NV6Rdv1a3I/hqdefault.jpg' },
    seconds: { type: 'string', default: '45' },
    headed: { type: 'boolean', default: false },
  },
});

const here = path.dirname(fileURLToPath(import.meta.url));
const extensionPath = path.resolve(here, '../../extension');
const mockHtml = await readFile(path.resolve(here, '../e2e/mock-ytm.html'), 'utf8');
const userDataDir = await mkdtemp(path.join(tmpdir(), 'ytm-glow-demo-'));

const context = await chromium.launchPersistentContext(userDataDir, {
  channel: 'chromium',
  headless: !values.headed,
  // Silent fake audio output keeps the beat analysis running on any audio setup.
  args: [`--disable-extensions-except=${extensionPath}`, `--load-extension=${extensionPath}`, '--disable-audio-output'],
});
await context.route('https://music.youtube.com/**', (route) => route.fulfill({ status: 200, contentType: 'text/html', body: mockHtml }));

const query = new URLSearchParams({ v: 'demo0000001', title: values.title, artist: values.artist, album: values.album, duration: values.duration, art: values.art });
const page = await context.newPage();
await page.goto(`https://music.youtube.com/watch?${query}`);
await page.click('#play');
await page.evaluate((t) => window.mock.seek(t), Number(values.seek));
console.log(`Playing "${values.title}" by ${values.artist} from ${values.seek}s for ${values.seconds}s…`);

const stop = async () => {
  await context.close();
  await rm(userDataDir, { recursive: true, force: true });
  process.exit(0);
};
process.on('SIGINT', stop);
setTimeout(stop, Number(values.seconds) * 1000);
