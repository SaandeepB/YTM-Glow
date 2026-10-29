# Lock-screen display (experimental)

**Off by default.** Popover → *Show on lock screen*. When on and the screen is
locked while music plays, YTM Glow shows the edge glow and a now-playing card
(album art, title, artist, the current lyric line lighting up word by word)
above the macOS lock screen.

## Why it needs private APIs

macOS has no public API for drawing over the lock screen. Ordinary windows,
even at `CGShieldingWindowLevel()` with `canBecomeVisibleWithoutLogin = true`,
sit below the lock screen. The lock screen is drawn in its own WindowServer
"space" at a high absolute level.

## Research (October 2026)

| Approach | Status |
|---|---|
| **SkyLight private space** (as in [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) by Lakr233) | MIT license. Maintained (last push July 2026, no open issues). About 60 lines: create a private space, raise its absolute level above the lock screen, move windows into it. **Used here (reimplemented, see below).** |
| `NSWindow.canBecomeVisibleWithoutLogin` + shielding level | Public, but not enough on its own: the window stays under the lock screen on macOS 14–26. |
| Screen saver module (`.saver`) | Public, but it's a separate bundle that runs as a screen saver, not on the lock screen, and would need its own bridge. Not pursued. |
| MediaRemote / Now Playing widget on the lock screen | Restricted for third-party apps on recent macOS, and only shows the system widget. Out of scope by design. |

The SkyLight calls (from `/System/Library/PrivateFrameworks/SkyLight.framework`):

```c
int      SLSMainConnectionID(void);
uint64_t SLSSpaceCreate(int cid, int one, int zero);
CGError  SLSSpaceSetAbsoluteLevel(int cid, uint64_t sid, int level);   // 400 = above screen lock (300)
CGError  SLSShowSpaces(int cid, CFArrayRef spaces);
CGError  SLSSpaceAddWindowsAndRemoveFromSpaces(int cid, uint64_t sid, CFArrayRef windows, int seven);
```

### Why not depend on SkyLightWindow directly

`Sources/YTMGlowCore/Experimental/SkyLightSpace.swift` reimplements the same
five calls with two fixes:

1. **Guarded symbol lookup.** SkyLightWindow bit-casts `dlsym` results without
   nil checks, so a macOS update that drops a symbol would crash the app as
   soon as the feature is touched. Here every symbol is checked;
   `SkyLightSpace.isSupported` is false and the popover says
   "Not available on this macOS" instead.
2. **64-bit space IDs.** SkyLightWindow declares space IDs as `Int32`, but
   WindowServer uses `uint64_t`. On arm64, passing a 32-bit value where a
   64-bit one is expected leaves the register's upper half undefined. In
   testing on macOS 26.6, space creation through the 32-bit declaration failed
   in a GUI process. With 64-bit IDs it succeeded every time (5/5 runs and
   3/3 test runs).

### Verified automatically

- All five symbols exist on macOS 26.6 (local) and macOS 15 (CI runner):
  `SkyLightSpaceTests.requiredPrivateSymbolsExist`.
- A real space can be created, raised to level 400 and shown, and a real
  window moved into it (all calls return success) on macOS 26.6:
  `YTMGLOW_SKYLIGHT_SMOKE=1 swift test --filter SkyLightSpaceTests` plus a GUI
  probe.
- Lock/unlock detection logic (`ScreenLockMonitorTests`).

**Not verified automatically:** that the card and glow are actually *visible*
on the lock screen. That needs a human at a locked Mac. See below.

## How it behaves

- Lock and unlock are detected from the distributed notifications
  `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`.
- On lock, with the option on: the app creates the private space once,
  rebuilds the glow's strip windows inside it, and opens a dedicated card
  window there (only while a track is playing).
- On unlock: the card window is closed and the glow strips are rebuilt as
  ordinary windows. Windows can't be moved back out of the space, so nothing
  is left above everything while you use the Mac.
- No extra permissions are needed. Music keeps playing in the browser while
  locked, and the extension keeps reporting as usual.

## Keep display awake while playing

Popover → Lyrics → *Keep display awake while playing* (off by default). It
holds an IOKit `PreventUserIdleDisplaySleep` power assertion (like
`caffeinate -d`, public API) only while music is playing, not paused or stale.
It's released on pause, track end, tab close, browser quit and app quit.
Verified end to end: `pmset -g assertions` shows
`"YTM Glow: music is playing"` while the demo plays, and nothing after.

Combine it with the lock-screen display to keep lyrics visible on a locked
Mac. Note it does not stop the Mac from *locking*. That's controlled by
System Settings → Lock Screen.

## What you must test by hand

Do these on the Mac you'll use, after building the app from this branch.

**Setup**
1. `scripts/build-app.sh && open "build/YTM Glow.app"`.
2. Popover: turn on **Show on lock screen** and **Keep display awake while
   playing**. Turn on Edge glow and Lyrics.
3. Play a song with synced lyrics in YouTube Music. Click once in the tab so
   beat sync is on. Confirm glow and lyrics work normally.
4. In a terminal: `log stream --level info --predicate 'subsystem == "io.github.saandeepb.ytmglow"'`

**Lock screen**
5. Lock with ⌃⌘Q. Expected within ~1 s, over the lock screen:
   - [ ] the edge glow around every display, pulsing with the beat;
   - [ ] a card in the lower middle of the main display (album art, title,
     artist, current lyric line lighting up word by word), clear of the clock
     and the password field.

   The log shows `Created lock-screen space …` the first time.
6. [ ] Type your password: the field still works. Nothing blocks clicks or
   typing, and the overlays don't take focus.
7. [ ] Use the media keys or AirPods to pause: card and glow disappear. Play:
   they come back.
8. [ ] Wait past your "turn display off" time: with *Keep display awake* on, the
   display stays on while music plays. Turn it off and repeat: the display
   sleeps as usual.
9. Unlock. Expected:
   - [ ] the card is gone;
   - [ ] the glow and normal lyrics overlay keep working;
   - [ ] nothing floats above Notification Center, menus or Mission Control.
     Open each to check.
10. [ ] Lock and unlock three times in a row: no duplicate cards, no leftover
   windows.

**Edge cases**
11. [ ] Lock with nothing playing: nothing is shown. Start music from AirPods or
   media keys while locked: card and glow appear.
12. [ ] With two displays: glow on both, card on the menu-bar display only.
13. [ ] Sleep and wake while locked (close the lid, open it): after wake, on the
   lock screen, overlays reappear when music plays.
14. [ ] Turn **Show on lock screen** off, lock: nothing shown. Normal glow and
   lyrics still work after unlock.
15. [ ] Fast user switching (if you have a second account): switch away and back.
   No overlays should show over the other user's login window. Report what
   you see.
16. [ ] Activity Monitor while locked and playing: YTM Glow CPU similar to unlocked
   (~1–3 %).

If anything misbehaves, turn the option off. It's isolated: with it off, the
private APIs are never called.

## Risks

- Private APIs can change or disappear in any macOS update. The guard turns
  the feature off instead of crashing, but it could also start behaving
  oddly. Treat it as experimental and re-test after each macOS update.
- Not App Store–compatible (irrelevant for a personal, ad-hoc signed app).
- Anyone looking at your locked Mac sees what you're listening to and the
  lyrics. That's the point, but keep it in mind.
