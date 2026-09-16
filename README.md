# koreader-live-sleepscreen

A [KOReader](https://koreader.rocks) user patch that keeps the Kindle sleep
screen up to date from a web endpoint — a dashboard, weather image, status
board, anything you can serve as a PNG. The image is refreshed

- **every time the device suspends** (you always fall asleep to current data), and
- **on scheduled hourly RTC wakeups** while the device sleeps (configurable
  daytime window), so the sleep screen stays current even when untouched.

Runs on jailbroken Kindles with KOReader on the **stock framework** — no
`framework stop`, no replacement launcher, reading is never interrupted.

```
┌─────────────────┐   GET  /your-image.png   ┌──────────────────────┐
│  your backend    │ ◄──────────────────────── │  Kindle + KOReader   │
│  (anything that  │                           │  + this patch        │
│  serves a PNG)   │ ◄──────────────────────── │                      │
└─────────────────┘  POST ?value=<minutes>     └──────────────────────┘
                      (optional reading sync)     shows the PNG as the
                                                  sleep screen, refreshed
                                                  at suspend + hourly
```

## What can it show?

Anything you can render into a PNG. This patch was born as the display
half of a **personal habit tracker**: a tiny serverless backend (Cloudflare
Worker + a small SQLite-style DB) logs habit ticks from a phone web app,
renders the current week into a hand-drawn SVG template — filled shapes
for done habits, partially filled ones for weekly counters — and serves it
as a grayscale PNG in the Kindle's exact panel size. The sleeping Kindle
keeps itself up to date all day, and reports reading minutes back via the
optional webhook. Other natural fits: weather dashboards, calendars/agenda
views, server status boards, Grafana panel renders — or simply a static
PNG that a cron job overwrites somewhere.

Tested on: Kindle Paperwhite 11 (2021, MediaTek), firmware 5.18.6,
KOReader v2026.03. The patch uses only KOReader APIs, so other KOReader
Kindle devices should work — reports welcome. Not usable on Special Offers
(ad-supported) devices: KOReader gets no `wakeup_mgr` there, so the
scheduled part silently disables itself (suspend-time refresh still works).
It assumes an already-jailbroken device — jailbreaking itself is out of
scope here (see the [Kindle Modding Wiki](https://kindlemodding.org)).

## Install

1. Copy `2-live-sleepscreen.lua` to `koreader/patches/` on the device
   (create the folder if missing). Keep the `2-` filename prefix — it is
   KOReader's user-patch priority convention ("run after the UI is ready");
   without a valid prefix the patch won't load.
2. Edit the CONFIG block at the top of the file — at minimum `IMAGE_URL`.
   If your endpoint needs auth, put a secret in a one-line file (no spaces)
   on the device and point `TOKEN_FILE` at it (sent as `X-Token` header);
   the default `TOKEN_FILE = nil` sends no auth header.
3. Restart KOReader (patches load at startup).
4. Put the device to sleep once while on Wi-Fi (this seeds the image file),
   then set in KOReader:
   - ⚙ → **Screen** → **Sleep screen** → **Wallpaper** →
     **Show custom image or cover on sleep screen**
   - ⚙ → **Screen** → **Sleep screen** → **Custom images** →
     **Choose image or document cover** → pick `koreader/wallpaper.png`
     (or your configured `TARGET`)
   - ⚙ → **Network**: leave *"Disable Wi-Fi connection when inactive"*
     **off**, turn *"Restore Wi-Fi connection on resume"* **on**.

## Your backend

The `IMAGE_URL` endpoint contract: a plain `GET` (plus the optional
`X-Token` header) answered with status **200** and an image KOReader can
decode (PNG recommended, at your device's panel resolution — 1236×1648 on
a PW11). Any other status quietly keeps the previous image. HTTPS goes
through LuaSec; self-signed certificates will fail. Note the scheduled
wake window uses the device's local time — make sure the Kindle's time
zone is set correctly.

Three recipes, from simple to fancy:

1. **Static file** — a PNG on any web host, overwritten by a cron job or
   CI pipeline. Zero server code.
2. **Render endpoint you already have** — Grafana's panel render URL, a
   Home Assistant camera/dashboard snapshot, etc. (put a proxy in front
   if it needs auth the patch can't do).
3. **Your own tiny service** — e.g. a Cloudflare Worker holding state in a
   DB, rendering it into an SVG template and rasterizing to PNG on request
   (resvg compiles to WASM and runs fine in a Worker; grayscale output
   keeps e-ink happy). That's the habit-tracker setup described above.

### Runtime switches (flag files, no restart needed)

Empty files at the USB root — the top-level folder you see when the Kindle
is plugged in over USB, which is `/mnt/us/` on the device. Create them with
`touch` or an empty text file (watch out for editors appending `.txt`):

| file (at USB root = `/mnt/us/`) | effect |
|---|---|
| `live-sleepscreen.nowake` | disable scheduled wakeups entirely (suspend refresh stays) |
| `live-sleepscreen.fasttest` | wake every 5 minutes, **ignoring the hour window** — testing only, battery hog, don't forget to delete it |

### Optional: reading-minutes webhook

If `SYNC_URL` is set, the patch reports this week's reading minutes from
KOReader's statistics plugin (which must be enabled — it is by default)
before each image fetch. The exact contract:

- `POST <SYNC_URL>?value=<integer minutes>` with an empty body
  (`Content-Length: 0`) and the `X-Token` header if configured.
- The response status is logged but otherwise ignored.
- The same total is re-sent every cycle while it is **greater than zero** —
  make your endpoint idempotent. A zero total is *not* sent, so don't rely
  on receiving `value=0` at the start of a week.
- "This week" starts at local midnight of `SYNC_WEEK_START`
  (os.date convention: 1 = Sunday … 7 = Saturday; default 1).
- `SYNC_LANG_PREFIXES` filters by book metadata language (prefix match,
  e.g. `{ "en" }`); the default empty table counts all books. Minutes are
  read from `STATS_DB` (default: KOReader's own
  `settings/statistics.sqlite3`).

Note: KOReader captures a book's language **only at its first open**, and
does not read the language field from MOBI files at all — use EPUBs with
proper `dc:language` metadata if you filter by language.

## How it works (and the two problems it solves)

This is the part that took research; sources below are the receipts.

### Problem 1: when to fetch

The obvious hook — KOReader's `Suspend` event — is **too late on Kindle**:
`Kindle:intoScreenSaver()` runs `Screensaver:setup()` + `show()` *before*
`powerd:beforeSuspend()` broadcasts `Suspend`
([frontend/device/kindle/device.lua](https://github.com/koreader/koreader/blob/master/frontend/device/kindle/device.lua)),
so a Suspend-hooked fetch would only show up on the *next* sleep. The patch
wraps **`Screensaver.setup`** instead: fetch first, then let the original
run. Wi-Fi is still up at that point (the Kindle suspend path has no Wi-Fi
teardown). Downloads go to a `.part` file renamed only on HTTP 200 — a
failed fetch keeps the previous image.

Scheduled wakeups use KOReader's own `Device.wakeup_mgr`, which **does
exist on Kindle** — it is instantiated in
[frontend/device/kindle/powerd.lua](https://github.com/koreader/koreader/blob/master/frontend/device/kindle/powerd.lua)
(not `device.lua`, which is why a casual grep misses it) with a
[MockRTC](https://github.com/koreader/koreader/blob/master/frontend/device/kindle/mockrtc.lua)
that commits the alarm via lipc `com.lab126.powerd rtcWakeup`
([property list](https://kindlemodding.org/kindle-apps-and-services/com.lab126.powerd.html))
during the framework's `readyToSuspend` window — which is why the alarm
must be armed *before* the device suspends (the `Screensaver.setup` hook
guarantees that). Support was added in KOReader commit
[926223c](https://github.com/koreader/koreader/commit/926223c192ab1e8f490f1e90673a8723d6750d14).

RTC wakes and user wakes are distinguished by KOReader itself: ~15 s after
a wake, `KindlePowerD:checkUnexpectedWakeup` runs the scheduled callback
only if the powerd state is still `screenSaver`/`suspended`. A user wake
goes to `active` instead, and the patch's `Screensaver.close` hook cancels
the pending alarm — so opening the device never triggers ghost refreshes,
and the alarm queue is re-armed at every suspend. The overlay-redraw
pattern follows [zmanim.koplugin](https://github.com/yparitcher/zmanim.koplugin)
(auto-updating sleep screen, same author as KOReader's Kindle RTC support)
and its stock-framework C counterpart
[kindle-zmanim](https://github.com/yparitcher/kindle-zmanim).

### Problem 2: Wi-Fi during sleep (the interesting one)

**In the `screenSaver` powerd state, the stock framework refuses to
associate Wi-Fi — on every level.** Verified empirically on FW 5.18.6
(all of the following leave the radio up but never connected, while the
identical requests connect within ~3 s once the device is `active`):

- enabling the radio (`com.lab126.cmd wirelessEnable`, `com.lab126.wifid
  enable` — what KOReader's `restoreWifiAsync()` does),
- an explicit association request (lipc `com.lab126.cmd ensureConnection
  "wifi:<essid>"` — what KOReader's own connect dialog sends),
- a full radio off/on cycle,
- `wpa_cli -i wlan0 reassociate` / `reconnect` (exists at `/usr/bin/wpa_cli`
  even on the MediaTek generation),
- a manual DHCP lease request via `/sbin/udhcpc`.

The patch still tries the quiet options first (they are believed to work on
some older i.MX devices — see
[MobileRead t=312150](https://www.mobileread.com/forums/showthread.php?t=312150),
[kindle-kt3_weatherdisplay](https://github.com/nicoh88/kindle-kt3_weatherdisplay_battery-optimized)),
and then falls back to the **dance**:

1. show the current wallpaper as a fullscreen overlay (non-flashing draw —
   the screen content doesn't change),
2. simulate a power-button press (`KindlePowerD:toggleSuspend`) — the
   device goes `active`, where Wi-Fi connects in ~3 s; the overlay hides
   the book the whole time, and the frontlight is switched off,
3. re-suspend ~2 s after connectivity (adaptive, ~10 s awake total) — the
   re-suspend runs the normal suspend-time refresh with working Wi-Fi and
   shows the fresh image.

Visible cost per scheduled refresh: two brief e-ink flashes (the resume
repaint and the final image change — the latter is deliberate, full
refreshes prevent ghosting). The book never appears. If the device wakes
for unrelated framework reasons, the patch does nothing (alarm-time
proximity guard), and if anything errors mid-cycle it logs and simply does
not re-arm — a bug can never keep the device awake.

### Battery

Each scheduled refresh costs a resume + Wi-Fi association + HTTPS fetch
(~10 s awake). Hourly daytime wakes also keep resetting the newer devices'
suspend-to-hibernate timer, so expect noticeably higher drain than stock
sleep — shrink the wake window (`WAKE_HOUR_MIN`/`MAX`, default 7 and 23,
i.e. wakes at 07:00 through 23:00) or create the `nowake` flag if that
bothers you. Overnight the device hibernates normally.

## Troubleshooting

Quick verification: create the `fasttest` flag, sleep the device on Wi-Fi,
wait ~6 minutes, and watch the screen update by itself — then delete the
flag.

Everything logs to `koreader/crash.log` (`/mnt/us/koreader/crash.log` on
the device) with the `live-sleepscreen:` prefix. A healthy scheduled cycle
looks like this (abridged — the real log interleaves `wifi wait`,
`remembered ESSID` and `sleep screen redrawn` lines):

```
live-sleepscreen: next scheduled refresh in 3441 s      (at suspend)
live-sleepscreen: early Wi-Fi restore on RTC wake
live-sleepscreen: RTC wake cycle
live-sleepscreen: quiet methods failed - brief wake to connect (dance)
live-sleepscreen: dance: Wi-Fi up after 5 s awake, re-suspending
live-sleepscreen: wallpaper updated
live-sleepscreen: next scheduled refresh in 3555 s
```

- No `next scheduled refresh` line at suspend → check for the `nowake`
  flag, or a Special Offers device (`no wakeup_mgr`).
- `no known ESSID` → the patch learns your network name at the first
  suspend that happens while connected; sleep the device once on Wi-Fi.
- Broken patch bricking startup → create `koreader/patches/.patches_disabled`
  to disable all user patches, or just delete the file.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with KOReader or Amazon.
Use at your own risk; it's your jailbroken device.
