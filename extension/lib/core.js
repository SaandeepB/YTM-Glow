/*
 * YTM Glow Bridge — shared, side-effect-free helpers.
 * Loaded as a classic script by the content script and service worker, and
 * via require() by the Node unit tests.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.YTMGlowCore = factory();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const PROTOCOL_VERSION = 1;
  const DEFAULT_PORT = 47816;
  const PORT_NAME = 'ytm-glow';
  const MAX_TEXT = 500;
  const MAX_ARTWORK = 10;

  /** Playing tabs report twice a second; paused tabs send a slow heartbeat. */
  const TICK_PLAYING_MS = 500;
  const TICK_PAUSED_MS = 5000;
  /** Audio levels are sampled about 30 times a second. */
  const LEVELS_INTERVAL_MS = 33;

  const BANDS = {
    bass: [30, 160],
    mid: [160, 2000],
    high: [2000, 10000],
  };

  function sanitizePort(value) {
    const n = Number(value);
    return Number.isInteger(n) && n >= 1024 && n <= 65535 ? n : DEFAULT_PORT;
  }

  /** Loopback only, by construction. */
  function wsUrl(port) {
    return `ws://127.0.0.1:${sanitizePort(port)}/ytm-glow/v1`;
  }

  function sourceId(tabId) {
    return `tab-${tabId}`;
  }

  function round(value, places = 3) {
    const f = 10 ** places;
    return Math.round(value * f) / f;
  }

  function finiteOrNull(value) {
    return typeof value === 'number' && Number.isFinite(value) ? round(value) : null;
  }

  function cleanText(value) {
    return typeof value === 'string' ? value.trim().slice(0, MAX_TEXT) : '';
  }

  /** Mean of byte FFT magnitudes for bins in [lo, hi) Hz, as 0…1. Bands never share bins. */
  function bandAverage(data, binHz, lo, hi) {
    if (!(binHz > 0)) return 0;
    const start = Math.max(1, Math.ceil(lo / binHz));
    const end = Math.min(data.length - 1, Math.ceil(hi / binHz) - 1);
    if (end < start) return 0;
    let sum = 0;
    for (let i = start; i <= end; i++) sum += data[i];
    return sum / ((end - start + 1) * 255);
  }

  /** Splits AnalyserNode byte frequency data into bass/mid/high levels (0…1). */
  function computeBands(frequencyData, sampleRate, fftSize) {
    const binHz = sampleRate / fftSize;
    return {
      bass: round(bandAverage(frequencyData, binHz, BANDS.bass[0], BANDS.bass[1])),
      mid: round(bandAverage(frequencyData, binHz, BANDS.mid[0], BANDS.mid[1])),
      high: round(bandAverage(frequencyData, binHz, BANDS.high[0], BANDS.high[1])),
    };
  }

  /** Track info from navigator.mediaSession.metadata, or null when there is none. */
  function readTrack(metadata, href) {
    if (!metadata) return null;
    const title = cleanText(metadata.title);
    if (!title) return null;

    const artwork = [];
    for (const image of Array.from(metadata.artwork || []).slice(0, MAX_ARTWORK)) {
      if (!image || typeof image.src !== 'string' || !image.src.startsWith('https://')) continue;
      const entry = { src: image.src.slice(0, 2048) };
      if (typeof image.sizes === 'string' && image.sizes) entry.sizes = image.sizes.slice(0, 64);
      if (typeof image.type === 'string' && image.type) entry.type = image.type.slice(0, 64);
      artwork.push(entry);
    }

    const track = { title, artist: cleanText(metadata.artist), artwork };
    const album = cleanText(metadata.album);
    if (album) track.album = album;
    try {
      const videoId = new URL(href).searchParams.get('v');
      if (videoId) track.videoId = videoId.slice(0, 64);
    } catch (_) {
      /* not a URL */
    }
    return track;
  }

  /** Playback fields from a <video>/<audio> element. */
  function readPlayback(media) {
    if (!media) return null;
    const HAVE_FUTURE_DATA = 3;
    const paused = !!media.paused;
    return {
      position: finiteOrNull(media.currentTime) ?? 0,
      duration: finiteOrNull(media.duration),
      paused,
      rate: finiteOrNull(media.playbackRate) || 1,
      ended: !!media.ended,
      waiting: !paused && typeof media.readyState === 'number' && media.readyState < HAVE_FUTURE_DATA,
    };
  }

  function buildState({ reason, track, playback, tap, ad }) {
    const message = { type: 'state', reason: reason || 'tick', track: track || null, playback: playback || null };
    if (tap) message.tap = tap;
    if (ad) message.ad = true;
    return message;
  }

  function trackKey(track) {
    return track ? `${track.videoId || ''}|${track.title}|${track.artist}` : '';
  }

  function tickInterval(playing) {
    return playing ? TICK_PLAYING_MS : TICK_PAUSED_MS;
  }

  /**
   * Routing a cross-origin media element into Web Audio silences it, so only
   * tap same-origin sources (YouTube Music streams through MSE blob: URLs).
   */
  function isTapSafeSource(src, origin) {
    if (typeof src !== 'string' || !src || typeof origin !== 'string') return false;
    if (src.startsWith(`blob:${origin}/`)) return true;
    try {
      return new URL(src).origin === origin;
    } catch (_) {
      return false;
    }
  }

  /** Parses a message from the app; returns null for anything unexpected. */
  function parseAppMessage(text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch (_) {
      return null;
    }
    if (!message || typeof message.type !== 'string') return null;
    switch (message.type) {
      case 'welcome':
      case 'config':
        return { type: message.type, wantLevels: message.wantLevels === true };
      case 'pong':
        return { type: 'pong' };
      default:
        return null;
    }
  }

  /** Exponential backoff with a little jitter. */
  class Backoff {
    constructor({ min = 500, max = 10000, factor = 2, jitter = 0.2, random = Math.random } = {}) {
      Object.assign(this, { min, max, factor, jitter, random });
      this.attempt = 0;
    }

    next() {
      const base = Math.min(this.max, this.min * this.factor ** this.attempt);
      this.attempt += 1;
      const spread = base * this.jitter * this.random();
      return Math.round(Math.min(this.max, base + spread));
    }

    reset() {
      this.attempt = 0;
    }
  }

  return {
    PROTOCOL_VERSION,
    DEFAULT_PORT,
    PORT_NAME,
    LEVELS_INTERVAL_MS,
    BANDS,
    sanitizePort,
    wsUrl,
    sourceId,
    computeBands,
    readTrack,
    readPlayback,
    buildState,
    trackKey,
    tickInterval,
    isTapSafeSource,
    parseAppMessage,
    Backoff,
  };
});
