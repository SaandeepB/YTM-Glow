// Loads the unpacked extension into Chromium, serves a mock music.youtube.com
// page, and plays the role of the YTM Glow app with a test WebSocket server.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { WebSocketServer } from 'ws';

const here = path.dirname(fileURLToPath(import.meta.url));
const extensionPath = path.resolve(here, '../../extension');
const TEST_PORT = 47917; // not the app's default, so a running app doesn't interfere
const mockHtml = await readFile(path.join(here, 'mock-ytm.html'), 'utf8');

/** Fake app: records every connection and message. */
class FakeApp {
  constructor(port) {
    this.connections = [];
    this.messages = [];
    this.wantLevels = true;
    this.server = new WebSocketServer({ host: '127.0.0.1', port });
    this.server.on('connection', (socket, request) => {
      const connection = { socket, origin: request.headers.origin, url: request.url };
      this.connections.push(connection);
      socket.on('message', (data) => {
        const message = JSON.parse(String(data));
        message.connection = this.connections.indexOf(connection);
        this.messages.push(message);
        if (message.type === 'hello') socket.send(JSON.stringify({ type: 'welcome', v: 1, app: 'Fake', version: 'test', wantLevels: this.wantLevels }));
        if (message.type === 'ping') socket.send('{"type":"pong"}');
      });
    });
  }

  of(type) { return this.messages.filter((m) => m.type === type); }
  states() { return this.of('state'); }

  async waitFor(predicate, { timeout = 10000, what = 'condition' } = {}) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const found = predicate(this);
      if (found) return found;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error(`timed out waiting for ${what}; last messages: ${JSON.stringify(this.messages.slice(-3))}`);
  }

  setWantLevels(value) {
    this.wantLevels = value;
    for (const { socket } of this.connections) if (socket.readyState === 1) socket.send(JSON.stringify({ type: 'config', wantLevels: value }));
  }

  close() { return new Promise((resolve) => this.server.close(resolve)); }
}

async function launch(extraArgs = []) {
  const userDataDir = await mkdtemp(path.join(tmpdir(), 'ytm-glow-e2e-'));
  const context = await chromium.launchPersistentContext(userDataDir, {
    channel: 'chromium',
    headless: true,
    // Fake audio output: the Web Audio clock runs even when the Mac's output
    // device isn't pulling samples (seen with some speaker/display setups).
    args: [`--disable-extensions-except=${extensionPath}`, `--load-extension=${extensionPath}`, '--disable-audio-output', ...extraArgs],
  });
  let [worker] = context.serviceWorkers();
  if (!worker) worker = await context.waitForEvent('serviceworker');
  await worker.evaluate((port) => chrome.storage.local.set({ port }), TEST_PORT);
  await context.route('https://music.youtube.com/**', (route) => route.fulfill({ status: 200, contentType: 'text/html', body: mockHtml }));
  const close = async () => {
    await context.close();
    await rm(userDataDir, { recursive: true, force: true });
  };
  return { context, worker, close };
}

let app;
before(() => { app = new FakeApp(TEST_PORT); });
after(async () => { await app.close(); });

test('extension streams track, playback and beat levels to the app', async () => {
  app.messages.length = 0;
  app.connections.length = 0;
  app.wantLevels = true;
  const browser = await launch();
  try {
    const page = await browser.context.newPage();
    await page.goto('https://music.youtube.com/watch?v=mockvid0001');

    // Service worker connects over loopback (no Local Network Access prompt for extensions).
    await app.waitFor((a) => a.of('hello').length > 0, { what: 'hello' });
    const hello = app.of('hello')[0];
    assert.equal(hello.v, 1);
    assert.equal(hello.client, 'ytm-glow-extension');
    assert.match(app.connections[0].origin, /^chrome-extension:\/\//);
    assert.equal(app.connections[0].url, '/ytm-glow/v1');

    // Paused page: state with track metadata, tap waiting for a click.
    const first = await app.waitFor((a) => a.states().find((s) => s.track), { what: 'first state' });
    assert.equal(first.track.title, 'Glass Lanterns');
    assert.equal(first.track.artist, 'The Paper Moths');
    assert.equal(first.track.album, 'Night Market');
    assert.equal(first.track.videoId, 'mockvid0001');
    assert.equal(first.track.artwork.length, 2);
    assert.match(first.source, /^tab-\d+$/);
    assert.equal(first.playback.paused, true);

    // A real click: user activation lets the audio tap start.
    await page.click('#play');
    const playing = await app.waitFor((a) => a.states().find((s) => s.playback && !s.playback.paused && s.tap === 'active'), { what: 'playing state with active tap' });
    assert.ok(playing.playback.duration > 29 && playing.playback.duration < 31);

    // ~30 Hz levels with a strong kick drum in the bass band.
    const levelsStart = app.of('levels').length;
    await new Promise((r) => setTimeout(r, 2000));
    const levels = app.of('levels').slice(levelsStart);
    assert.ok(levels.length >= 30, `expected ~60 levels in 2 s, got ${levels.length}`);
    const maxBass = Math.max(...levels.map((l) => l.bass));
    const minBass = Math.min(...levels.map((l) => l.bass));
    assert.ok(maxBass > 0.4, `bass peaks (${maxBass})`);
    assert.ok(maxBass - minBass > 0.15, `bass pulses with the beat (${minBass}..${maxBass})`);
    for (const l of levels) for (const k of ['bass', 'mid', 'high']) assert.ok(l[k] >= 0 && l[k] <= 1);

    // State about twice a second while playing.
    const statesWhilePlaying = app.states().filter((s) => s.playback && !s.playback.paused).length;
    assert.ok(statesWhilePlaying >= 3, `got ${statesWhilePlaying} playing states`);

    // Tapping never mutes or pauses the page.
    const info = await page.evaluate(() => window.mock.info());
    assert.equal(info.muted, false);
    assert.equal(info.volume, 1);
    assert.equal(info.paused, false);
    assert.ok(info.time > 1.5, `playback advanced (${info.time})`);

    // Pause → immediate paused state, levels stop.
    await page.evaluate(() => window.mock.pause());
    await app.waitFor((a) => a.states().at(-1)?.playback?.paused === true, { what: 'paused state' });
    await new Promise((r) => setTimeout(r, 300));
    const afterPause = app.of('levels').length;
    await new Promise((r) => setTimeout(r, 500));
    assert.equal(app.of('levels').length, afterPause, 'no levels while paused');

    // Seek while paused → state at the new position.
    await page.evaluate(() => window.mock.seek(12));
    const seeked = await app.waitFor((a) => a.states().find((s) => s.reason === 'seeked'), { what: 'seeked state' });
    assert.ok(Math.abs(seeked.playback.position - 12) < 0.1);

    // Track change (SPA navigation) → new track key reported.
    await page.evaluate(() => window.mock.nextTrack());
    const next = await app.waitFor((a) => a.states().find((s) => s.track?.title === 'Paper Moths'), { what: 'next track' });
    assert.equal(next.track.videoId, 'mockvid0002');

    // The app turns beat sync off → levels stop even while playing.
    await page.evaluate(() => window.mock.play());
    await app.waitFor((a) => a.states().at(-1)?.playback?.paused === false, { what: 'playing again' });
    app.setWantLevels(false);
    await new Promise((r) => setTimeout(r, 300));
    const offCount = app.of('levels').length;
    await new Promise((r) => setTimeout(r, 500));
    assert.equal(app.of('levels').length, offCount, 'no levels after wantLevels=false');
    const offState = await app.waitFor((a) => a.states().filter((s) => s.tap === 'off').at(-1), { what: 'tap off state' });
    assert.ok(offState);

    // App restarts: socket drops, extension reconnects and resends state.
    const connectionsBefore = app.connections.length;
    for (const { socket } of app.connections) socket.terminate();
    await app.waitFor((a) => a.connections.length > connectionsBefore && a.of('hello').some((h) => h.connection === connectionsBefore), { what: 'reconnect', timeout: 15000 });
    await app.waitFor((a) => a.states().some((s) => s.connection === connectionsBefore && s.track), { what: 'state after reconnect' });

    // Closing the tab tells the app the source is gone.
    const source = app.states().at(-1).source;
    await page.close();
    await app.waitFor((a) => a.of('clear').some((c) => c.source === source), { what: 'clear on tab close' });
  } finally {
    await browser.close();
  }
});

test('audio tap waits for user activation and stays off without it', async () => {
  app.messages.length = 0;
  app.connections.length = 0;
  app.wantLevels = true;
  // Allow scripted playback without a gesture, as when YTM autoplays.
  const browser = await launch(['--autoplay-policy=no-user-gesture-required']);
  try {
    const page = await browser.context.newPage();
    // Note: page.evaluate() counts as a user gesture in Playwright, so the page starts itself.
    await page.goto('https://music.youtube.com/watch?v=mockvid0001&autoplay=1');
    await app.waitFor((a) => a.of('hello').length > 0, { what: 'hello' });
    const pending = await app.waitFor((a) => a.states().find((s) => s.playback && !s.playback.paused && s.tap === 'pending'), { what: 'pending tap' });
    assert.ok(pending);
    await new Promise((r) => setTimeout(r, 500));
    assert.equal(app.of('levels').length, 0, 'no levels before activation');
    assert.equal(app.states().some((s) => s.tap === 'active'), false);

    // First click anywhere activates the page; the tap starts and audio keeps playing.
    await page.mouse.click(5, 5);
    await app.waitFor((a) => a.states().some((s) => s.tap === 'active'), { what: 'active tap after click' });
    await app.waitFor((a) => a.of('levels').length > 5, { what: 'levels after click' });
    const info = await page.evaluate(() => window.mock.info());
    assert.equal(info.paused, false);
    assert.equal(info.muted, false);
  } finally {
    await browser.close();
  }
});

test('no app running: the extension keeps retrying quietly', async () => {
  const browser = await launch();
  await app.close();
  try {
    const page = await browser.context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e));
    await page.goto('https://music.youtube.com/watch?v=mockvid0001');
    await page.click('#play');
    await new Promise((r) => setTimeout(r, 2500));
    assert.deepEqual(errors, []);
    assert.equal((await page.evaluate(() => window.mock.info())).paused, false, 'playback unaffected');

    // App comes back → extension connects within the backoff window.
    app = new FakeApp(TEST_PORT);
    await app.waitFor((a) => a.of('hello').length > 0, { what: 'hello after app start', timeout: 15000 });
    await app.waitFor((a) => a.states().some((s) => s.track?.title === 'Glass Lanterns'), { what: 'state after app start' });
  } finally {
    await browser.close();
  }
});
