# Manual QA checklist

Automation covers the parser, timing, palette, protocol, bridge server, and the
extension against a mock player in headless Chromium. These checks need a real
Mac, real displays, and real YouTube Music. Run them before merging a release.

Setup: build with `scripts/build-app.sh`, open `build/YTM Glow.app`, load the
extension (README → "Load the browser extension"), and sign in to
music.youtube.com in Chrome.

To watch what the app is doing:

```sh
log stream --level info --predicate 'subsystem == "io.github.saandeepb.ytmglow"'
```

## 1. Real YouTube Music in Chrome

- [ ] Open music.youtube.com and play a well-known song. Within ~2 s the menu bar popover shows the title, artist and album art, and the status pill says **Connected**.
- [ ] Before clicking anything in the tab (e.g. playback resumed by YTM itself), the popover says **Click the YTM tab** and the glow is steady. After one click in the tab it says **Beat sync** and the glow pulses.
- [ ] The glow pulses on the kick/bass, not randomly. Try a song with a strong beat and a quiet acoustic one.
- [ ] Audio sounds exactly the same with the extension on and off (volume, no crackle, no delay you can notice). Change YTM's volume slider: still works.
- [ ] Glow colors match the album art. Skip to a track with very different art: colors cross-fade.
- [ ] Synced lyrics appear (**Synced lyrics** in the popover) and the current line's words light up one at a time, roughly with the singing. Note: word timing inside a line is estimated.
- [ ] A track without synced lyrics shows **No synced lyrics** / **No lyrics found** and no overlay.
- [ ] Pause: lyrics fade out and the glow fades away within ~1 s. Play: both return.
- [ ] Seek forward and back with the progress bar: lyrics jump to the right line within ~0.5 s.
- [ ] Skip track, previous track, shuffle: lyrics and colors follow.
- [ ] Music videos (not just songs) and an ad (free account): glow and lyrics hide during the ad.
- [ ] Timing offset +/- in the popover moves the highlight later/earlier.
- [ ] Brave, Edge and Arc: load the extension the same way and repeat a quick play/pause/seek check.
- [ ] Two YTM tabs: the one you most recently started playing wins.

## 2. Recovery

- [ ] Quit the app while music plays, relaunch it: within ~5 s glow and lyrics return without touching the browser.
- [ ] Quit Chrome while music plays: glow and lyrics stop within a few seconds. Reopen Chrome and play: they return.
- [ ] Reload the extension in chrome://extensions, then reload the YTM tab: works again.
- [ ] Close the YTM tab: glow and lyrics stop immediately.
- [ ] Turn Wi-Fi off mid-song: playback state keeps working (it's local); lyrics for new songs show "Lyrics offline"; **Retry lyrics lookup** works once back online.

## 3. Displays

- [ ] Glow appears around every connected display, including the notch area on a MacBook.
- [ ] Plug in / unplug a display, change resolution or arrangement while playing: glow re-fits all displays within a second.
- [ ] Lyrics appear on the display with the menu bar. Move the menu bar to another display in System Settings → Displays: lyrics follow.
- [ ] Clicks pass through the glow and lyrics everywhere (click a button under the Beam lyrics, drag a window by its edge under the glow).
- [ ] The glow and lyrics appear on every Space and in Mission Control they don't show up as windows.
- [ ] Try each lyrics style (Beam, Cascade, Capsule) and the size slider.

## 4. Full-screen apps

- [ ] Put Safari or a video player in full screen (green button). Glow and lyrics stay visible above it.
- [ ] Switch between a full-screen Space and the desktop with a trackpad swipe: overlays stay put.
- [ ] Full-screen YouTube Music itself (Chrome full screen): overlays still visible.

## 5. Sleep / wake and lock

- [ ] Close the lid (or Apple menu → Sleep) while music plays. Wake: the app is still running, the extension reconnects, and glow and lyrics resume when music plays.
- [ ] Lock the screen (⌃⌘Q) while music plays: overlays are not shown on the lock screen in this version (that's Phase 2, experimental). Unlock: overlays are back.
- [ ] Leave the Mac idle with nothing playing for 10 minutes: Activity Monitor shows YTM Glow at ~0% CPU.

## 6. Settings and performance

- [ ] Each control in the popover takes effect immediately: glow on/off, music sync / steady, thickness, intensity, album/custom colors (both wells), lyrics on/off, style, colors, size, timing.
- [ ] Settings survive quitting and relaunching the app.
- [ ] With music playing, Activity Monitor → CPU: note YTM Glow and WindowServer %. Expected: YTM Glow ~1–3 %. WindowServer rises by roughly 5–15 points with music sync on two 5K displays (less on one display, ~0 in steady mode).
- [ ] The app has no Dock icon and no window besides the popover and overlays.
- [ ] No permission prompts appear (no Screen Recording, Microphone, Accessibility). Chrome shows no "local network access" prompt.
