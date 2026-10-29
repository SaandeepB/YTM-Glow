# YTM Glow

A personal macOS menu bar app that turns what's playing in **YouTube Music**
into light and lyrics:

- **Edge glow** — soft ambient light around the edges of every display, in the
  album art's colors (a two-color gradient). It pulses with the beat or holds a
  steady glow. Click-through, on every Space, above full-screen apps.
- **Synced lyrics** — the current line on screen with its words lighting up one
  at a time, in three styles: **Beam** (one big line above the Dock),
  **Cascade** (previous / current / next on a frosted card) and **Capsule** (a
  compact pill under the menu bar).
- **Menu bar only** — no Dock icon; one popover holds every setting.
- **Experimental: lock screen** — optionally keeps the glow and a now-playing
  lyrics card visible over the lock screen (private macOS APIs, off by
  default; see [docs/LOCK_SCREEN.md](docs/LOCK_SCREEN.md)), plus an option to
  keep the display awake while music plays.

YouTube Music runs in the browser, so a small Chrome extension (works in
Chrome, Brave, Edge and Arc) reports what's playing to the app over a local
WebSocket. Nothing leaves your Mac except lyric lookups (LRCLIB) and album-art
downloads (Google's image hosts).

Requires macOS 14 or later on Apple silicon. Not affiliated with YouTube or Google.

## Build the app

You need Xcode 15+ (or a Swift 5.9+ toolchain with the macOS SDK).

```sh
git clone https://github.com/SaandeepB/YTM-Glow.git
cd YTM-Glow
scripts/build-app.sh            # → build/YTM Glow.app (release, ad-hoc signed)
open "build/YTM Glow.app"
```

Optionally drag `build/YTM Glow.app` to `/Applications`. Because it's ad-hoc
signed (not notarized), the first launch from Finder may need right-click →
**Open**.

For development, `swift run YTMGlow` runs the app without bundling.

## Load the browser extension

1. Click the YTM Glow menu bar icon → **Browser extension…**. This copies the
   extension to `~/Library/Application Support/YTMGlow/ChromeExtension` and
   shows it in Finder. (Or use the `extension/` folder of this repo.)
2. Open `chrome://extensions` (or `brave://extensions`, `edge://extensions`,
   Arc → Extensions → Manage), turn on **Developer mode**.
3. Click **Load unpacked** and choose that folder.
4. Reload any open music.youtube.com tabs and play something.
5. Click once anywhere in the YouTube Music tab. Browsers only allow the beat
   tap after a user gesture; until then the glow is steady.

The extension's toolbar popup shows whether it's connected to the app.

## Use

Click the menu bar icon:

- **Edge glow**: on/off, *Music sync* vs *Steady*, thickness, intensity,
  album-art vs custom colors (two color wells).
- **Lyrics**: on/off, style (Beam / Cascade / Capsule), album-art vs custom
  highlight color, size, a timing offset (+ shows lyrics later), and *Keep
  display awake while playing*.
- **Show on lock screen** (experimental, private API).
- **Browser extension…** and **Quit**.

The popover also shows the current track, whether synced lyrics were found,
and whether beat sync is active.

## How it works

```
music.youtube.com tab                    Chrome extension                     YTM Glow.app
┌──────────────────────────┐   port    ┌──────────────────────┐  WebSocket  ┌──────────────────────────┐
│ content.js               │ ────────▶ │ background.js        │ ──────────▶ │ BridgeServer 127.0.0.1   │
│  mediaSession.metadata   │  state    │ (service worker)     │  JSON       │ PlayerEngine             │
│  <video> position/paused │  2×/s     │  one socket, retries │  ws://127.  │  ├ LyricsService ─▶ LRCLIB│
│  Web Audio analyser      │  levels   │  with backoff        │  0.0.1:47816│  ├ ArtworkLoader ─▶ palette│
│   (pass-through)         │  ~30×/s   │                      │             │  ├ GlowController (CA)   │
└──────────────────────────┘           └──────────────────────┘             │  └ LyricsPresenter (UI)  │
                                                                            └──────────────────────────┘
```

- **Playback**: the content script reads `navigator.mediaSession.metadata`
  (title, artist, album, artwork) and the page's `<video>` (position, duration,
  paused, rate). It sends the full state about twice a second and immediately on
  play, pause, seek, rate and track changes. The app extrapolates the position
  between reports.
- **Beat**: after the first click in the tab, the content script routes the
  `<video>` through a Web Audio `AnalyserNode` and straight back out to the
  speakers, unchanged. It never mutes or alters playback; it only taps
  same-origin (MSE `blob:`) media, because routing cross-origin media into Web
  Audio would silence it, and it never routes audio into a suspended context.
  If the tap can't be created the glow falls back to steady. Levels are only
  measured while the app asks for them (music-sync glow on).
- **Bridge**: the service worker keeps one WebSocket to `ws://127.0.0.1:47816`
  and reconnects with backoff (0.5 s → 5 s) while a YouTube Music tab is open.
  The message format is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md), so
  other players can plug in.
- **Glow**: four thin, borderless, click-through strip windows per display
  (above full-screen apps, on all Spaces). Core Animation draws the gradient
  once; beats only change the windows' alpha, which WindowServer applies while
  compositing, capped at 24 updates a second. When nothing plays the windows
  are ordered out, so the app idles at 0 % CPU.
- **Lyrics**: fetched from [LRCLIB](https://lrclib.net) (free, no key) and cached
  on disk in `~/Library/Caches/YTMGlow/lyrics`. Titles and artists are cleaned
  first (drops "(Official Video)", "feat. …", "- Topic", "VEVO", release
  notes like "- Remastered 2011"). The app tries `/api/get` (exact match, then
  without album, then with only the first artist), then `/api/search` and picks
  the closest duration with synced lyrics (±10 s). It retries once after 1 s on
  HTTP 503. Misses are re-checked after 3 days.
- **Album colors**: artwork is downloaded only from `https` hosts the player
  uses (`*.googleusercontent.com`, `*.ytimg.com`, `*.ggpht.com`, redirects
  included) and the two colors are extracted locally.

### Word timing is estimated

LRCLIB lyrics are timed per **line**, not per word. YTM Glow estimates when
each word is sung: every word gets a share of the line weighted by its
syllable count (vowel groups for Latin, Cyrillic and Greek script, one per
Hangul block, one per Chinese/Japanese character), sung at a natural pace and
not stretched across instrumental gaps. So the highlight follows the line
closely but individual words can be early or late. If a lyric file carries
real word timestamps (enhanced LRC `<mm:ss.xx>` tags), those are used instead.
Use the timing offset if a whole song runs early or late.

## Privacy and security

- The app listens on **127.0.0.1 only** (verified: connecting via the LAN IP
  is refused).
- Browsers send an `Origin` header on WebSocket handshakes and WebSockets
  aren't covered by CORS, so the app refuses any handshake from a web page
  origin. Only extensions and native clients can connect.
- The extension asks for one permission (`storage`, for the port setting) and
  only runs on `https://music.youtube.com/*`.
- No macOS permissions: no Screen Recording, Microphone or Accessibility.
  It doesn't use the private MediaRemote / Now Playing APIs.
- The only private API is the optional lock-screen display (SkyLight), and it
  is never called unless you turn that option on.
- Chrome's Local Network Access rules don't block the extension:
  the WebSocket is opened from the extension's service worker, and the
  automated test connects without a prompt in Chromium 156.

## Performance

Measured on an Apple silicon Mac with **two 5K displays**, music sync on, Beam
lyrics, 120 BPM test track (Activity Monitor-style `top` samples):

| | YTM Glow CPU | WindowServer CPU |
|---|---|---|
| Nothing playing | 0.0 % | baseline |
| Playing (glow + lyrics) | ~1.3 % | +6 to +16 points over baseline |
| Playing, glow only | ~1.1 % | — |
| Playing, lyrics only | ~1.1 % | — |

WindowServer cost comes from recompositing the screen edges on each beat
update; *Steady* mode avoids it. It scales with display size and count, so
expect less on a single built-in display.

## Testing

```sh
swift build
swift test                                   # 68 Swift tests: parser, timing, cleanup,
                                             # palette, protocol, LRCLIB client, cache,
                                             # and a loopback WebSocket integration suite

cd extension-tests
npm test                                     # extension unit tests (Node, no install needed)
npm install && npx playwright install chromium
npm run test:e2e                             # loads the unpacked extension in Chromium against
                                             # a mock YouTube Music page and a fake app server
node demo/demo.mjs --headed                  # drives the real app with a fake player
                                             # posing as a real song (real lyrics + colors)
```

CI (GitHub Actions, macOS) runs `swift build`, `swift test`, the extension unit
tests and the app bundle build. The Playwright tests run locally.

What automation can't cover (real YouTube Music, multiple displays,
full-screen apps, sleep/wake, lock screen) is in
[docs/MANUAL_QA.md](docs/MANUAL_QA.md).

## Not yet verified

- Real music.youtube.com in a real browser. The extension is tested against a
  mock page that imitates YouTube Music's `mediaSession` and `<video>`, and
  the full app is tested end to end with that mock. If YouTube Music changes how
  it exposes playback, the content script may need an update.
- Glow above full-screen apps, multiple-display hot-plug, sleep/wake, and the
  look of each lyrics style. These need eyes on a screen; see MANUAL_QA.md.
- Brave, Edge and Arc (only Chromium was automated).
- The lock-screen display on an actually locked screen (the private calls are
  verified to succeed; visibility needs a human). Step-by-step checks are in
  [docs/LOCK_SCREEN.md](docs/LOCK_SCREEN.md).

## Troubleshooting

- **Popover says "Bridge error"**: another program uses port 47816. Quit it, or
  pick a different port in the extension popup (Advanced) *and* the app (not
  yet configurable in the app).
- **"Waiting for browser"**: check the extension is loaded and enabled, and
  reload the YouTube Music tab.
- **Steady glow, "Click the YTM tab"**: click once inside the YouTube Music page.
- **Logs**: `log stream --level info --predicate 'subsystem == "io.github.saandeepb.ytmglow"'`

## Layout

```
Sources/YTMGlowCore/   UI-free logic: bridge server + protocol, lyrics, palette, beat envelope, engine
Sources/YTMGlow/       menu bar app: overlays, popover, settings
Tests/YTMGlowCoreTests Swift Testing suites + fixtures
extension/             the unpacked Chrome extension (MV3)
extension-tests/       Node unit tests, Playwright e2e, demo script (kept out of extension/)
scripts/build-app.sh   builds and ad-hoc signs build/YTM Glow.app
docs/                  PROTOCOL.md, MANUAL_QA.md, LOCK_SCREEN.md
```
