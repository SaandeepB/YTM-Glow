'use strict';

const C = globalThis.YTMGlowCore;
const dot = document.getElementById('dot');
const statusText = document.getElementById('status');
const detail = document.getElementById('detail');
const portInput = document.getElementById('port');

async function refresh() {
  let state;
  try {
    state = await chrome.runtime.sendMessage({ kind: 'status' });
  } catch (_) {
    state = null;
  }
  if (!state) {
    statusText.textContent = 'Service worker unavailable';
    return;
  }
  if (state.connected) {
    dot.className = 'dot ok';
    statusText.textContent = 'Connected to YTM Glow';
    detail.textContent = state.wantLevels ? 'Beat sync on' : 'Beat sync off (steady glow or glow disabled)';
  } else if (state.tabs > 0) {
    dot.className = 'dot wait';
    statusText.textContent = 'Looking for the app…';
    detail.textContent = `Is YTM Glow running? (port ${state.port})`;
  } else {
    dot.className = 'dot';
    statusText.textContent = 'Idle';
    detail.textContent = 'Open music.youtube.com to start.';
  }
}

async function loadPort() {
  const { port } = await chrome.storage.local.get('port');
  portInput.value = C.sanitizePort(port);
}

document.getElementById('save').addEventListener('click', async () => {
  const port = C.sanitizePort(portInput.value);
  portInput.value = port;
  await chrome.storage.local.set({ port });
  setTimeout(refresh, 800);
});

loadPort();
refresh();
setInterval(refresh, 1500);
