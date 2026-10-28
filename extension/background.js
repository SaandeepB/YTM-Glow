/*
 * YTM Glow Bridge — service worker.
 *
 * Holds one WebSocket to the YTM Glow app on 127.0.0.1 and relays messages
 * from YouTube Music tabs. Reconnects with backoff while any tab is open.
 */
importScripts('lib/core.js');

const C = self.YTMGlowCore;
const KEEPALIVE_MS = 20000;

/** tabId -> runtime.Port */
const ports = new Map();
let socket = null;
let reconnectTimer = null;
let keepAliveTimer = null;
let appConfig = { wantLevels: false };
const backoff = new C.Backoff({ min: 500, max: 5000 });
const status = { connected: false, since: Date.now(), port: C.DEFAULT_PORT, lastError: null };

// ---- Tabs ---------------------------------------------------------------------------

chrome.runtime.onConnect.addListener((port) => {
  const tabId = port.sender && port.sender.tab && port.sender.tab.id;
  if (port.name !== C.PORT_NAME || typeof tabId !== 'number') return;

  const previous = ports.get(tabId);
  ports.set(tabId, port);
  if (previous && previous !== port) previous.disconnect();

  port.onMessage.addListener((message) => relayFromTab(tabId, message));
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (ports.get(tabId) !== port) return;
    ports.delete(tabId);
    send({ type: 'clear', source: C.sourceId(tabId) });
  });

  port.postMessage({ type: 'config', wantLevels: appConfig.wantLevels });
  ensureSocket();
});

function relayFromTab(tabId, message) {
  if (!message || (message.type !== 'state' && message.type !== 'levels')) return;
  ensureSocket();
  send({ ...message, source: C.sourceId(tabId) });
}

function broadcastToTabs(message) {
  for (const port of ports.values()) {
    try {
      port.postMessage(message);
    } catch (_) {
      /* tab went away */
    }
  }
}

// ---- Socket -------------------------------------------------------------------------

async function configuredPort() {
  try {
    const { port } = await chrome.storage.local.get('port');
    return C.sanitizePort(port);
  } catch (_) {
    return C.DEFAULT_PORT;
  }
}

async function ensureSocket() {
  if (socket || reconnectTimer) return;
  const port = await configuredPort();
  if (socket || reconnectTimer) return;
  status.port = port;

  let ws;
  try {
    ws = new WebSocket(C.wsUrl(port));
  } catch (error) {
    status.lastError = String(error);
    scheduleReconnect();
    return;
  }
  socket = ws;

  ws.onopen = () => {
    backoff.reset();
    setConnected(true);
    send({
      type: 'hello',
      v: C.PROTOCOL_VERSION,
      client: 'ytm-glow-extension',
      version: chrome.runtime.getManifest().version,
      browser: browserName(),
    });
    keepAliveTimer = setInterval(() => send({ type: 'ping' }), KEEPALIVE_MS);
    // Have every tab report immediately so the app catches up.
    broadcastToTabs({ type: 'resend' });
  };

  ws.onmessage = (event) => {
    const message = C.parseAppMessage(event.data);
    if (!message) return;
    if (message.type === 'welcome' || message.type === 'config') {
      appConfig = { wantLevels: message.wantLevels };
      broadcastToTabs({ type: 'config', wantLevels: appConfig.wantLevels });
    }
  };

  ws.onclose = () => {
    if (socket !== ws) return;
    socket = null;
    clearInterval(keepAliveTimer);
    keepAliveTimer = null;
    setConnected(false);
    // Without the app there is nothing to measure levels for.
    if (appConfig.wantLevels) {
      appConfig = { wantLevels: false };
      broadcastToTabs({ type: 'config', wantLevels: false });
    }
    if (ports.size > 0) scheduleReconnect();
  };

  ws.onerror = () => {
    status.lastError = 'Could not reach the YTM Glow app';
  };
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (ports.size > 0) ensureSocket();
  }, backoff.next());
}

function send(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  try {
    socket.send(JSON.stringify(message));
  } catch (_) {
    /* closing */
  }
}

function setConnected(connected) {
  if (status.connected !== connected) status.since = Date.now();
  status.connected = connected;
  if (connected) status.lastError = null;
  chrome.action.setBadgeText({ text: connected ? '' : ports.size > 0 ? '…' : '' }).catch(() => {});
}

function browserName() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const named = brands.find((b) => !/Not.?A.?Brand|Chromium/i.test(b.brand));
  const brand = named || brands.find((b) => /Chromium/i.test(b.brand));
  return brand ? `${brand.brand} ${brand.version}` : 'Chromium';
}

// ---- Popup & settings -------------------------------------------------------------------

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message && message.kind === 'status') {
    sendResponse({ ...status, tabs: ports.size, wantLevels: appConfig.wantLevels });
  }
  return false;
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.port) return;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  backoff.reset();
  if (socket) {
    const old = socket;
    socket = null;
    old.close();
    setConnected(false);
  }
  if (ports.size > 0) ensureSocket();
});
