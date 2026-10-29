import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const C = require('../../extension/lib/core.js');

test('wsUrl is always loopback and sanitizes the port', () => {
  assert.equal(C.wsUrl(47816), 'ws://127.0.0.1:47816/ytm-glow/v1');
  assert.equal(C.wsUrl('50000'), 'ws://127.0.0.1:50000/ytm-glow/v1');
  assert.equal(C.wsUrl(80), `ws://127.0.0.1:${C.DEFAULT_PORT}/ytm-glow/v1`, 'privileged ports rejected');
  assert.equal(C.wsUrl('evil.example:1'), `ws://127.0.0.1:${C.DEFAULT_PORT}/ytm-glow/v1`);
  assert.equal(C.wsUrl(undefined), `ws://127.0.0.1:${C.DEFAULT_PORT}/ytm-glow/v1`);
});

test('computeBands splits frequency data into bass/mid/high', () => {
  const fftSize = 1024;
  const sampleRate = 48000; // 46.875 Hz per bin
  const data = new Uint8Array(fftSize / 2);
  // Loud bass (bins 1-3 ≈ 47-140 Hz), silence elsewhere.
  data[1] = 255; data[2] = 255; data[3] = 255;
  const bassOnly = C.computeBands(data, sampleRate, fftSize);
  assert.ok(bassOnly.bass > 0.7, `bass ${bassOnly.bass}`);
  assert.equal(bassOnly.mid, 0);
  assert.equal(bassOnly.high, 0);

  data.fill(0);
  for (let i = 50; i < 200; i++) data[i] = 128; // ≈ 2.3-9.4 kHz
  const highOnly = C.computeBands(data, sampleRate, fftSize);
  assert.equal(highOnly.bass, 0);
  assert.ok(highOnly.high > 0.4 && highOnly.high <= 0.5, `high ${highOnly.high}`);

  const silent = C.computeBands(new Uint8Array(512), 44100, 1024);
  assert.deepEqual(silent, { bass: 0, mid: 0, high: 0 });
  for (const value of Object.values(C.computeBands(new Uint8Array(512).fill(255), 44100, 1024))) {
    assert.ok(value >= 0 && value <= 1);
  }
});

test('readTrack reads mediaSession metadata and the video id', () => {
  const metadata = {
    title: '  Glass Lanterns ',
    artist: 'The Paper Moths',
    album: 'Night Market',
    artwork: [
      { src: 'https://lh3.googleusercontent.com/a=w60-h60', sizes: '60x60', type: 'image/jpeg' },
      { src: 'http://insecure.example/x.jpg', sizes: '544x544' },
      { src: 'javascript:alert(1)' },
      { src: 'https://lh3.googleusercontent.com/a=w544-h544', sizes: '544x544' },
    ],
  };
  const track = C.readTrack(metadata, 'https://music.youtube.com/watch?v=abc123XYZ00&list=RD');
  assert.deepEqual(track, {
    title: 'Glass Lanterns',
    artist: 'The Paper Moths',
    album: 'Night Market',
    videoId: 'abc123XYZ00',
    artwork: [
      { src: 'https://lh3.googleusercontent.com/a=w60-h60', sizes: '60x60', type: 'image/jpeg' },
      { src: 'https://lh3.googleusercontent.com/a=w544-h544', sizes: '544x544' },
    ],
  });
  assert.equal(C.readTrack(null, 'https://music.youtube.com/'), null);
  assert.equal(C.readTrack({ title: '   ' }, 'https://music.youtube.com/'), null);
  const noAlbum = C.readTrack({ title: 'X', artist: 'Y', album: '' }, 'not a url');
  assert.equal('album' in noAlbum, false);
  assert.equal('videoId' in noAlbum, false);
  assert.equal(C.readTrack({ title: 'x'.repeat(2000) }, '').title.length, 500);
});

test('readPlayback sanitizes media element values', () => {
  assert.deepEqual(
    C.readPlayback({ currentTime: 12.34567, duration: 200.2, paused: false, playbackRate: 1, ended: false, readyState: 4 }),
    { position: 12.346, duration: 200.2, paused: false, rate: 1, ended: false, waiting: false },
  );
  // Live streams / not loaded: duration NaN or Infinity.
  const loading = C.readPlayback({ currentTime: 0, duration: NaN, paused: false, playbackRate: 1, ended: false, readyState: 1 });
  assert.equal(loading.duration, null);
  assert.equal(loading.waiting, true, 'playing but without data is buffering');
  assert.equal(C.readPlayback({ currentTime: 3, duration: Infinity, paused: true, readyState: 1 }).waiting, false);
  assert.equal(C.readPlayback({ currentTime: 3, duration: 10, paused: false, playbackRate: 0, readyState: 4 }).rate, 1);
  assert.equal(C.readPlayback(null), null);
});

test('buildState produces protocol messages', () => {
  const state = C.buildState({ reason: 'seeked', track: { title: 'A', artist: 'B', artwork: [] }, playback: { position: 1 }, tap: 'active' });
  assert.equal(state.type, 'state');
  assert.equal(state.reason, 'seeked');
  assert.equal(state.tap, 'active');
  assert.equal('ad' in state, false);
  assert.equal(C.buildState({ ad: true }).ad, true);
  assert.equal(C.buildState({}).track, null);
  JSON.parse(JSON.stringify(state));
});

test('trackKey and tick intervals', () => {
  assert.equal(C.trackKey(null), '');
  assert.equal(C.trackKey({ title: 'A', artist: 'B', videoId: 'v1' }), 'v1|A|B');
  assert.notEqual(C.trackKey({ title: 'A', artist: 'B', videoId: 'v1' }), C.trackKey({ title: 'A', artist: 'B', videoId: 'v2' }));
  assert.equal(C.tickInterval(true), 500, 'playing tabs report twice a second');
  assert.ok(C.tickInterval(false) > 1000);
  assert.ok(C.LEVELS_INTERVAL_MS >= 30 && C.LEVELS_INTERVAL_MS <= 40, '~30 Hz levels');
});

test('isTapSafeSource only allows same-origin media', () => {
  const origin = 'https://music.youtube.com';
  assert.equal(C.isTapSafeSource('blob:https://music.youtube.com/5b0e-uuid', origin), true);
  assert.equal(C.isTapSafeSource('https://music.youtube.com/audio.webm', origin), true);
  assert.equal(C.isTapSafeSource('https://rr3---sn.googlevideo.com/videoplayback?x', origin), false);
  assert.equal(C.isTapSafeSource('blob:https://evil.example/uuid', origin), false);
  assert.equal(C.isTapSafeSource('', origin), false);
  assert.equal(C.isTapSafeSource(undefined, origin), false);
});

test('parseAppMessage accepts only known app messages', () => {
  assert.deepEqual(C.parseAppMessage('{"type":"welcome","v":1,"wantLevels":true}'), { type: 'welcome', wantLevels: true });
  assert.deepEqual(C.parseAppMessage('{"type":"config","wantLevels":"yes"}'), { type: 'config', wantLevels: false });
  assert.deepEqual(C.parseAppMessage('{"type":"pong"}'), { type: 'pong' });
  assert.equal(C.parseAppMessage('{"type":"eval","code":"x"}'), null);
  assert.equal(C.parseAppMessage('not json'), null);
  assert.equal(C.parseAppMessage('null'), null);
});

test('Backoff grows exponentially, caps, and resets', () => {
  const backoff = new C.Backoff({ min: 500, max: 10000, jitter: 0, random: () => 0 });
  assert.deepEqual([backoff.next(), backoff.next(), backoff.next(), backoff.next(), backoff.next(), backoff.next()], [500, 1000, 2000, 4000, 8000, 10000]);
  assert.equal(backoff.next(), 10000);
  backoff.reset();
  assert.equal(backoff.next(), 500);
  const jittery = new C.Backoff({ min: 1000, max: 10000, jitter: 0.2, random: () => 1 });
  assert.equal(jittery.next(), 1200);
});

test('manifest is MV3, scoped to YouTube Music, with minimal permissions', async () => {
  const { readFile } = await import('node:fs/promises');
  const manifest = JSON.parse(await readFile(new URL('../../extension/manifest.json', import.meta.url), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.content_scripts[0].matches, ['https://music.youtube.com/*']);
  assert.deepEqual(manifest.content_scripts[0].js, ['lib/core.js', 'content.js']);
  assert.deepEqual(manifest.permissions, ['storage']);
  assert.equal(manifest.host_permissions, undefined);
});

test('extension folder has no files Chrome refuses to load', async () => {
  const { readdir } = await import('node:fs/promises');
  const entries = await readdir(new URL('../../extension/', import.meta.url), { recursive: true });
  const reserved = entries.filter((name) => name.split('/').some((part) => part.startsWith('_')));
  assert.deepEqual(reserved, []);
});

test('every icon the manifest references exists', async () => {
  const { readFile, access } = await import('node:fs/promises');
  const base = new URL('../../extension/', import.meta.url);
  const manifest = JSON.parse(await readFile(new URL('manifest.json', base), 'utf8'));
  const paths = [...Object.values(manifest.icons || {}), ...Object.values(manifest.action?.default_icon || {})];
  assert.ok(paths.length >= 4);
  for (const path of paths) await access(new URL(path, base));
});
