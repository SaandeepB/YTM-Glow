# YTM Glow bridge protocol (v1)

The app listens for playback reports from "sources" (today: the YTM Glow Bridge
browser extension) over a local WebSocket. Anything that can open a WebSocket
can plug in: another browser extension, a desktop player plugin, a script.

## Transport

| | |
|---|---|
| URL | `ws://127.0.0.1:47816/ytm-glow/v1` (the path is informational; any path is accepted) |
| Bind | `127.0.0.1` only. The app never listens on other interfaces. |
| Frames | UTF-8 text frames, one JSON object per frame, ≤ 256 KiB |
| Origin | Handshakes whose `Origin` is a web page (`http(s)://…`, `null`, `file://`) are refused with HTTP 400. Allowed: no `Origin` header (native clients), `chrome-extension://…`, `moz-extension://…`, `safari-web-extension://…`. |
| Liveness | A client must send a valid message within 10 s of connecting and at least one message every 90 s (send `ping`). WebSocket-level pings are answered automatically. |
| Limits | 8 simultaneous connections. |

Unknown message types are ignored, so clients may add fields and types. Numbers
are JSON numbers; times are seconds.

## Client → app

### `hello`
Sent once after connecting.

```json
{ "type": "hello", "v": 1, "client": "ytm-glow-extension", "version": "0.1.0", "browser": "Google Chrome 141" }
```

The app answers with `welcome`.

### `state`
The full playback state of one source (one browser tab). Send it about twice a
second while playing, immediately on play / pause / seek / rate change / track
change, and every few seconds while paused as a heartbeat.

```json
{
  "type": "state",
  "source": "tab-17",
  "reason": "seeked",
  "track": {
    "title": "Glass Lanterns",
    "artist": "The Paper Moths",
    "album": "Night Market",
    "videoId": "abc123XYZ00",
    "artwork": [
      { "src": "https://lh3.googleusercontent.com/…=w544-h544", "sizes": "544x544", "type": "image/jpeg" }
    ]
  },
  "playback": {
    "position": 42.137,
    "duration": 200.2,
    "paused": false,
    "rate": 1,
    "ended": false,
    "waiting": false
  },
  "tap": "active",
  "ad": false
}
```

| Field | Required | Meaning |
|---|---|---|
| `source` | yes | Stable id for this source within the connection (the extension uses `tab-<tabId>`). |
| `reason` | no | Why it was sent: `tick`, `track`, `play`, `pause`, `seeked`, `ratechange`, `waiting`, `resend`, … Informational. |
| `track` | yes (may be `null`) | `title` and `artist` are required strings; `album`, `videoId`, `artwork` optional. |
| `track.artwork[].src` | | Only `https` images on `*.googleusercontent.com`, `*.ytimg.com`, `*.ggpht.com` are fetched; others are ignored. |
| `playback` | yes (may be `null`) | `position` required. `duration` may be `null` (unknown/live). `rate` defaults to 1. `waiting` = playing but buffering (position not advancing). |
| `tap` | no | Audio-level tap status: `active`, `pending` (waiting for a click in the tab), `failed`, `off`. Anything other than `active` makes the glow steady. |
| `ad` | no | `true` while an ad plays; the app hides the glow and lyrics. |

The app extrapolates `position` between reports using `rate` and its own
monotonic clock, so reports don't need to be frequent for smooth lyrics.

### `levels`
Audio loudness of the active source, about 30 times a second while playing.
Only sent when the app asked for it (`wantLevels: true`).

```json
{ "type": "levels", "source": "tab-17", "bass": 0.82, "mid": 0.41, "high": 0.12 }
```

Values are 0…1: the mean byte magnitude (`AnalyserNode.getByteFrequencyData`,
fftSize 1024, −85…−20 dB) over 30–160 Hz, 160–2000 Hz and 2–10 kHz. Levels
from a source other than the active one are ignored.

### `clear`
The source went away (tab closed or navigated off the player).

```json
{ "type": "clear", "source": "tab-17" }
```

Closing the connection clears all of its sources.

### `ping`
Keep-alive. The app replies `pong`.

## App → client

### `welcome`
Reply to `hello`.

```json
{ "type": "welcome", "v": 1, "app": "YTM Glow", "version": "0.1.0", "wantLevels": true }
```

### `config`
Sent to every client when the app's needs change (e.g. the glow is switched to
steady or off, so levels are no longer useful).

```json
{ "type": "config", "wantLevels": false }
```

### `pong`
```json
{ "type": "pong" }
```

## Choosing the active source

Several tabs or browsers can report at once. The app shows the source that
most recently **started** playing; while nothing plays, the last active source
stays selected. A source that is "playing" but silent for 6 s is treated as
paused (frozen or crashed tab).

## Minimal client example

```js
const ws = new WebSocket('ws://127.0.0.1:47816/ytm-glow/v1');
ws.onopen = () => {
  ws.send(JSON.stringify({ type: 'hello', v: 1, client: 'my-player', version: '1.0' }));
  ws.send(JSON.stringify({
    type: 'state', source: 'main',
    track: { title: 'Glass Lanterns', artist: 'The Paper Moths' },
    playback: { position: 0, duration: 200, paused: false, rate: 1 },
  }));
};
```
