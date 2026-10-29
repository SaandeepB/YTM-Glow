/*
 * YTM Glow Bridge — content script for music.youtube.com.
 *
 * Reads track metadata from navigator.mediaSession and playback from the
 * page's <video>, and (optionally) taps the audio with Web Audio to measure
 * bass/mid/high levels. Everything is sent to the service worker over a
 * runtime port; the worker owns the WebSocket to the app.
 */
(() => {
  'use strict';

  const C = globalThis.YTMGlowCore;
  if (!C || globalThis.__ytmGlowBridgeLoaded) return;
  globalThis.__ytmGlowBridgeLoaded = true;

  let port = null;
  let portRetry = null;
  let alive = true;
  let wantLevels = false;
  let media = null;
  let lastTrackKey = null;
  let lastSentAt = 0;
  let tickTimer = null;
  let pendingReason = null;

  const tap = {
    state: 'off', // off | pending | active | failed
    context: null,
    analyser: null,
    buffer: null,
    tapped: new WeakSet(),
    failed: new WeakSet(),
    timer: null,
    waitingForActivation: false,
  };

  // ---- Port to the service worker -------------------------------------------------

  function extensionAlive() {
    try {
      return Boolean(chrome.runtime && chrome.runtime.id);
    } catch (_) {
      return false;
    }
  }

  function connect() {
    if (!alive || port) return;
    if (!extensionAlive()) return shutdown();
    try {
      port = chrome.runtime.connect({ name: C.PORT_NAME });
    } catch (_) {
      return shutdown();
    }
    port.onMessage.addListener(onWorkerMessage);
    port.onDisconnect.addListener(() => {
      port = null;
      void chrome.runtime.lastError;
      if (!extensionAlive()) return shutdown();
      clearTimeout(portRetry);
      portRetry = setTimeout(connect, 1000);
    });
    queueState('connect');
  }

  function post(message) {
    if (!port) connect();
    if (!port) return;
    try {
      port.postMessage(message);
    } catch (_) {
      port = null;
    }
  }

  function onWorkerMessage(message) {
    if (!message || typeof message.type !== 'string') return;
    if (message.type === 'config') {
      wantLevels = message.wantLevels === true;
      if (wantLevels) maybeTap();
      updateLevelsLoop();
      queueState('config');
    } else if (message.type === 'resend') {
      queueState('resend');
    }
  }

  /** Extension was reloaded or removed: stop everything quietly. */
  function shutdown() {
    alive = false;
    clearInterval(tickTimer);
    clearTimeout(portRetry);
    stopLevels();
  }

  // ---- Media element ----------------------------------------------------------------

  const MEDIA_EVENTS = ['play', 'playing', 'pause', 'seeked', 'ratechange', 'durationchange', 'loadedmetadata', 'ended', 'emptied', 'waiting'];

  function onMediaEvent(event) {
    queueState(event.type);
    if (event.type === 'play' || event.type === 'playing') maybeTap();
    updateLevelsLoop();
  }

  function findMedia() {
    const candidate = document.querySelector('video') || document.querySelector('audio');
    if (candidate === media) return media;
    if (media) for (const type of MEDIA_EVENTS) media.removeEventListener(type, onMediaEvent);
    media = candidate;
    if (media) {
      for (const type of MEDIA_EVENTS) media.addEventListener(type, onMediaEvent, { passive: true });
      maybeTap();
    }
    return media;
  }

  function isAd() {
    return Boolean(document.querySelector('#movie_player.ad-showing, .ytmusic-player-bar .advertisement-badge'));
  }

  // ---- State reporting --------------------------------------------------------------

  /** Coalesces bursts of media events into one message. */
  function queueState(reason) {
    if (pendingReason) return;
    pendingReason = reason;
    queueMicrotask(() => {
      const why = pendingReason;
      pendingReason = null;
      sendState(why);
    });
  }

  function sendState(reason) {
    if (!alive) return;
    const element = findMedia();
    const track = C.readTrack(navigator.mediaSession && navigator.mediaSession.metadata, location.href);
    if (!track && !element) return;
    lastTrackKey = C.trackKey(track);
    lastSentAt = Date.now();
    post(C.buildState({ reason, track, playback: C.readPlayback(element), tap: wantLevels ? tap.state : 'off', ad: isAd() }));
  }

  function tick() {
    if (!alive) return;
    const element = findMedia();
    const track = C.readTrack(navigator.mediaSession && navigator.mediaSession.metadata, location.href);
    if (C.trackKey(track) !== lastTrackKey) return queueState('track');
    const playing = Boolean(element && !element.paused && !element.ended);
    if (Date.now() - lastSentAt >= C.tickInterval(playing) - 50) queueState('tick');
  }

  // ---- Web Audio tap ----------------------------------------------------------------

  function hasUserActivation() {
    return Boolean(navigator.userActivation && navigator.userActivation.hasBeenActive);
  }

  function waitForActivation() {
    if (tap.waitingForActivation) return;
    tap.waitingForActivation = true;
    const onActivate = () => {
      tap.waitingForActivation = false;
      window.removeEventListener('pointerdown', onActivate, true);
      window.removeEventListener('keydown', onActivate, true);
      maybeTap();
    };
    window.addEventListener('pointerdown', onActivate, true);
    window.addEventListener('keydown', onActivate, true);
  }

  function maybeTap() {
    if (!wantLevels || !media) return;
    const element = media;
    if (tap.tapped.has(element)) {
      tap.state = 'active';
      return;
    }
    if (tap.failed.has(element)) {
      tap.state = 'failed';
      return;
    }
    // Wait until the element is streaming so its source can be checked.
    if (!element.currentSrc && !element.src) return;
    if (!C.isTapSafeSource(element.currentSrc || element.src, location.origin)) {
      tap.failed.add(element);
      tap.state = 'failed';
      queueState('tap');
      return;
    }
    if (!hasUserActivation()) {
      tap.state = 'pending';
      waitForActivation();
      return;
    }
    createTap(element);
  }

  async function createTap(element) {
    try {
      if (!tap.context) tap.context = new AudioContext();
      if (tap.context.state !== 'running') {
        try {
          await tap.context.resume();
        } catch (_) {
          /* handled below */
        }
      }
      // Never route audio into a suspended context: that would silence playback.
      if (tap.context.state !== 'running') {
        tap.state = 'pending';
        waitForActivation();
        return;
      }
      if (tap.tapped.has(element) || element !== media) return;

      // Throws (leaving playback untouched) if something else already owns the element.
      const source = tap.context.createMediaElementSource(element);
      const analyser = tap.context.createAnalyser();
      analyser.fftSize = 1024;
      analyser.smoothingTimeConstant = 0.5;
      analyser.minDecibels = -85;
      analyser.maxDecibels = -20;
      source.connect(tap.context.destination); // audio passes through unchanged
      source.connect(analyser);

      tap.tapped.add(element);
      tap.analyser = analyser;
      tap.buffer = new Uint8Array(analyser.frequencyBinCount);
      tap.state = 'active';
      tap.context.onstatechange = () => {
        if (tap.context.state === 'suspended' && media && !media.paused) tap.context.resume().catch(() => {});
      };
    } catch (_) {
      tap.failed.add(element);
      tap.state = 'failed';
    }
    updateLevelsLoop();
    queueState('tap');
  }

  function updateLevelsLoop() {
    const run = alive && wantLevels && tap.state === 'active' && media && tap.tapped.has(media) && !media.paused && !media.ended;
    if (run && !tap.timer) {
      tap.timer = setInterval(sendLevels, C.LEVELS_INTERVAL_MS);
    } else if (!run) {
      stopLevels();
    }
  }

  function stopLevels() {
    if (tap.timer) clearInterval(tap.timer);
    tap.timer = null;
  }

  function sendLevels() {
    if (!tap.analyser || !tap.context) return;
    tap.analyser.getByteFrequencyData(tap.buffer);
    const levels = C.computeBands(tap.buffer, tap.context.sampleRate, tap.analyser.fftSize);
    post({ type: 'levels', bass: levels.bass, mid: levels.mid, high: levels.high });
  }

  // ---- Start ---------------------------------------------------------------------------

  connect();
  findMedia();
  tickTimer = setInterval(tick, 250);
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) connect();
  });
})();
