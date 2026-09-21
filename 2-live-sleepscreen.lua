-- KOReader user patch: keep the sleep screen up to date from a web endpoint.
--
-- Fetches an image over HTTPS whenever the device suspends, and additionally
-- on scheduled RTC wakeups (hourly, within a configurable daytime window)
-- while the device sleeps - so the sleep screen always shows current data
-- (a dashboard, weather, a status board, ...). Works on jailbroken Kindles
-- running KOReader on the STOCK framework (no framework-stop hacks).
--
-- See the README for how this works and why - especially the "dance": in the
-- screenSaver power state the stock framework refuses to (re)associate Wi-Fi
-- no matter how it is asked, so the patch briefly simulates a power-button
-- press to connect, hiding the transition behind a fullscreen overlay.
--
-- Install: copy to koreader/patches/ , edit the CONFIG block, restart KOReader.

------------------------------------------------------------------ CONFIG ----

-- The image to show. Rendered as-is; match your device's panel resolution
-- for best results (e.g. 1236x1648 for a Paperwhite 11).
local IMAGE_URL = "https://example.com/status.png"

-- Optional: file containing one line with a secret (no spaces); sent as
-- "X-Token" header with every request. nil = endpoint needs no auth.
-- If set but the file is missing, the patch refuses to fetch (fail closed).
local TOKEN_FILE = nil -- e.g. "/mnt/us/live-sleepscreen.token"

-- Where the image is stored. Point KOReader's sleep screen at this file
-- (Screen -> Sleep screen -> "custom image or cover", see README).
local TARGET = "/mnt/us/koreader/wallpaper.png"

-- Scheduled wakeups fire at full hours within [WAKE_HOUR_MIN, WAKE_HOUR_MAX]
-- (device-local time). Outside the window the device sleeps undisturbed.
local WAKE_HOUR_MIN = 7
local WAKE_HOUR_MAX = 23

-- Flag files (create/delete at the USB root, no restart needed):
local NOWAKE_FILE = "/mnt/us/live-sleepscreen.nowake" -- disables scheduled wakeups
local FASTTEST_FILE = "/mnt/us/live-sleepscreen.fasttest" -- 5-minute wakes (testing!)

-- Optional: report weekly reading minutes (from KOReader's statistics plugin)
-- to a webhook before each fetch. POSTs to SYNC_URL .. "?value=<minutes>"
-- with the X-Token header. Set SYNC_URL to enable, e.g.
-- "https://example.com/sync/reading". Minutes are summed since the start of
-- the current week (SYNC_WEEK_START, os.date wday: 1=Sunday .. 7=Saturday).
-- SYNC_LANG_PREFIXES filters by book metadata language (prefix match, e.g.
-- { "en" } or { "fr", "de" }); empty table = count all books.
local SYNC_URL = nil
local SYNC_LANG_PREFIXES = {}
local SYNC_WEEK_START = 1
local STATS_DB = "/mnt/us/koreader/settings/statistics.sqlite3"

--------------------------------------------------------------- END CONFIG ---

local Device = require("device")
local Screensaver = require("ui/screensaver")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ImageWidget = require("ui/widget/imagewidget")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local Blitbuffer = require("ffi/blitbuffer")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Screen = Device.screen
local LOG = "live-sleepscreen:"

local function readToken()
    if not TOKEN_FILE then return nil end
    local f = io.open(TOKEN_FILE, "r")
    if not f then return nil end
    local token = f:read("*l")
    f:close()
    if token then token = token:gsub("%s+", "") end
    if token == "" then return nil end
    return token
end

local function authHeaders(token, extra)
    local headers = extra or {}
    if token then headers["X-Token"] = token end
    return headers
end

-- ---- optional reading statistics sync ----

local function weekStartTimestamp()
    local t = os.date("*t")
    local days_back = (t.wday - SYNC_WEEK_START) % 7
    local midnight = os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
    return midnight - days_back * 86400
end

-- Sum this week's reading time (minutes, floored) of books whose metadata
-- language starts with one of SYNC_LANG_PREFIXES, from the statistics plugin
-- DB (book.language, page_stat_data.start_time/duration). nil on any problem.
local function readWeeklyMinutes()
    if lfs.attributes(STATS_DB, "mode") ~= "file" then
        logger.info(LOG, "no statistics DB at", STATS_DB)
        return nil
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        logger.info(LOG, "lua-ljsqlite3 unavailable")
        return nil
    end
    local lang_clause = "1=1" -- empty prefix list: count all books
    if #SYNC_LANG_PREFIXES > 0 then
        local likes = {}
        for _, p in ipairs(SYNC_LANG_PREFIXES) do
            table.insert(likes, "LOWER(b.language) LIKE '" .. p:lower():gsub("'", "''") .. "%'")
        end
        lang_clause = table.concat(likes, " OR ")
    end
    local ok2, minutes = pcall(function()
        local conn = SQ3.open(STATS_DB, "ro")
        local seconds = conn:rowexec(string.format([[
            SELECT COALESCE(SUM(psd.duration), 0)
            FROM page_stat_data psd
            JOIN book b ON b.id = psd.id_book
            WHERE psd.start_time >= %d AND (%s);
        ]], weekStartTimestamp(), lang_clause))
        conn:close()
        return math.floor(tonumber(seconds or 0) / 60)
    end)
    if not ok2 then
        logger.info(LOG, "statistics query failed:", tostring(minutes))
        return nil
    end
    return minutes
end

local function syncReading(token)
    if not SYNC_URL then return end
    local minutes = readWeeklyMinutes()
    if not minutes then return end
    logger.info(LOG, "reading this week:", minutes, "min")
    if minutes <= 0 then return end
    socketutil:set_timeout(5, 10)
    local code = socket.skip(1, http.request({
        url = SYNC_URL .. "?value=" .. minutes,
        method = "POST",
        headers = authHeaders(token, { ["Content-Length"] = "0" }),
        sink = ltn12.sink.null(),
    }))
    socketutil:reset_timeout()
    logger.info(LOG, "reading sync:", tostring(code))
end

-- ---- wallpaper fetch ----

local function fetchWallpaper(token)
    local tmp = TARGET .. ".part"
    local fh = io.open(tmp, "wb")
    if not fh then return end
    -- tight timeouts: this can block the sleep-screen paint
    socketutil:set_timeout(5, 10)
    local code = socket.skip(1, http.request({
        url = IMAGE_URL,
        method = "GET",
        headers = authHeaders(token),
        sink = socketutil.file_sink(fh),
    }))
    socketutil:reset_timeout()
    if code == 200 then
        os.rename(tmp, TARGET)
        logger.info(LOG, "wallpaper updated")
    else
        pcall(function() fh:close() end) -- sink never closed it on early failure
        os.remove(tmp)
        logger.info(LOG, "fetch failed:", tostring(code))
    end
end

-- ESSID of the connected network, captured whenever we are online. Needed on
-- RTC wakes: in the screenSaver powerd state, enabling the radio does NOT
-- make the framework associate - that needs an explicit lipc
-- ensureConnection "wifi:<essid>" (what NetworkMgr:authenticateNetwork sends).
local last_essid

local function rememberEssid()
    if not NetworkMgr.getCurrentNetwork then return end
    local ok, nw = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
    local ssid = ok and nw and (nw.ssid or nw.essid) or nil
    if ssid and ssid ~= "" then
        last_essid = ssid
        -- don't write the full network name into crash.log (users paste logs
        -- into bug reports)
        logger.info(LOG, "remembered ESSID", ssid:sub(1, 2) .. "…")
    end
end

local function requestAssociation()
    if not NetworkMgr.authenticateNetwork then return end
    if not last_essid then
        rememberEssid() -- unlikely to work while asleep, but try
        if not last_essid then
            logger.info(LOG, "no known ESSID, cannot request association")
            return
        end
    end
    local ok, err = pcall(NetworkMgr.authenticateNetwork, NetworkMgr, { ssid = last_essid })
    logger.info(LOG, "association requested for", last_essid:sub(1, 2) .. "…", ok and "" or tostring(err))
end

local function refresh()
    local token = readToken()
    if TOKEN_FILE and not token then
        logger.info(LOG, "no token file at", TOKEN_FILE)
        return
    end
    if not (NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) then
        logger.info(LOG, "Wi-Fi down, keeping previous wallpaper")
        return
    end
    rememberEssid()
    pcall(syncReading, token)
    fetchWallpaper(token)
end

-- ---- scheduled RTC refresh while asleep ----

local overlay -- widget shown over the sleep screen after an RTC refresh
local wakeupCallback -- forward declaration: identity doubles as the cancel handle

-- Seconds until the next full hour whose hour lies in [WAKE_HOUR_MIN,
-- WAKE_HOUR_MAX] (device-local); outside the window -> WAKE_HOUR_MIN:00 next morning.
local function nextWakeSeconds()
    if lfs.attributes(FASTTEST_FILE, "mode") == "file" then
        return 300
    end
    local now = os.time()
    local t = os.date("*t", now)
    local target = os.time({ year = t.year, month = t.month, day = t.day, hour = t.hour + 1, min = 0, sec = 0 })
    -- the alarm must still be in the future when powerd commits it ~10 s into
    -- the suspend sequence; too close -> skip to the following hour
    if target - now < 120 then
        target = target + 3600
    end
    local tt = os.date("*t", target)
    if tt.hour < WAKE_HOUR_MIN or tt.hour > WAKE_HOUR_MAX then
        local day = tt.day
        if tt.hour > WAKE_HOUR_MAX then day = day + 1 end
        target = os.time({ year = tt.year, month = tt.month, day = day, hour = WAKE_HOUR_MIN, min = 0, sec = 0 })
    end
    return target - now
end

local function scheduleWakeup()
    if not Device.wakeup_mgr then
        logger.info(LOG, "no wakeup_mgr on this device, scheduled refresh disabled")
        return
    end
    if lfs.attributes(NOWAKE_FILE, "mode") == "file" then
        logger.info(LOG, "nowake flag present, scheduled refresh disabled")
        return
    end
    Device.wakeup_mgr:removeTasks(nil, wakeupCallback)
    local secs = nextWakeSeconds()
    Device.wakeup_mgr:addTask(secs, wakeupCallback)
    logger.info(LOG, "next scheduled refresh in", secs, "s")
end

-- Redraw the sleep screen with the freshly fetched image: a full-screen image
-- widget shown over the existing screensaver (the pattern zmanim.koplugin uses).
-- refresh_mode: "full" (flashing, default - proper for a changed image) or
-- "ui" (non-flashing - for the dance overlay, whose content is identical to
-- what is already on screen).
local function redrawSleepScreen(refresh_mode)
    if overlay then
        UIManager:close(overlay)
        overlay = nil
    end
    local image = ImageWidget:new({
        file = TARGET,
        file_do_cache = false,
        alpha = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        scale_factor = 0,
    })
    overlay = ScreenSaverWidget:new({
        widget = image,
        background = Blitbuffer.COLOR_WHITE,
        covers_fullscreen = true,
    })
    overlay.modal = true
    overlay.dithered = true
    UIManager:show(overlay, refresh_mode or "full")
    logger.info(LOG, "sleep screen redrawn (" .. (refresh_mode or "full") .. ")")
end

-- One RTC refresh cycle. A Lua error anywhere -> log, do NOT re-arm (the next
-- user suspend re-arms); transient network trouble -> keep old image, re-arm.
local function runCycle()
    local ok, err = pcall(refresh)
    if not ok then
        logger.info(LOG, "refresh error, not rescheduling:", tostring(err))
        return
    end
    local ok2, err2 = pcall(redrawSleepScreen)
    if not ok2 then
        logger.info(LOG, "redraw error, not rescheduling:", tostring(err2))
        return
    end
    scheduleWakeup()
end

-- The stock framework's connection manager refuses to associate while powerd
-- is in the screenSaver state (verified: ensureConnection, radio cycling,
-- wpa_cli reassociate and a manual udhcpc lease request all fail; the same
-- request connects in ~3 s when active). Last resorts, in order: wpa_cli +
-- udhcpc straight at the supplicant (quiet - works on some devices), then
-- the "dance": simulate a power-button press so the device goes active
-- (Wi-Fi connects there), re-suspend ~2 s after connectivity; the suspend-
-- time refresh then runs with working Wi-Fi and re-arms the alarm.
local dance = false
local dance_polls = 0
local dance_started = 0
local danceResuspend
danceResuspend = function()
    if not dance then return end
    -- a timer chain revived after a suspend must never act: it would
    -- re-suspend the device right after the user wakes it
    if os.time() - dance_started > 60 then
        dance = false
        logger.info(LOG, "dance: stale timer, aborting")
        return
    end
    dance_polls = dance_polls + 1
    local state = Device.powerd.getPowerdState and Device.powerd:getPowerdState() or nil
    if state == "active" and NetworkMgr:isConnected() then
        dance = false
        logger.info(LOG, "dance: Wi-Fi up after", dance_polls, "s awake, re-suspending")
        UIManager:scheduleIn(2, function() Device.powerd:toggleSuspend() end)
        return
    end
    if dance_polls >= 20 then
        dance = false
        logger.info(LOG, "dance: timeout (state:", tostring(state), "), re-suspending anyway")
        if state == "active" then Device.powerd:toggleSuspend() end
        return
    end
    UIManager:scheduleIn(1, danceResuspend)
end

local function tryWpaCli(cmd)
    local f = io.popen("which wpa_cli 2>/dev/null")
    local path = f and f:read("*l") or nil
    if f then f:close() end
    if not path or path == "" then
        logger.info(LOG, "wpa_cli not available")
        return
    end
    logger.info(LOG, "wpa_cli", cmd, "via", path)
    os.execute(path .. " -i wlan0 " .. cmd .. " >/dev/null 2>&1")
end

-- wpa_cli can associate at L2, but nothing hands out an IP in screenSaver
-- state - so ask busybox udhcpc for a lease ourselves (backgrounded).
local function tryUdhcpc()
    local f = io.popen("which udhcpc 2>/dev/null")
    local path = f and f:read("*l") or nil
    if f then f:close() end
    if not path or path == "" then
        logger.info(LOG, "udhcpc not available")
        return
    end
    logger.info(LOG, "requesting DHCP lease via", path)
    os.execute(path .. " -i wlan0 -n -q -t 2 -T 2 >/dev/null 2>&1 &")
end

local wifi_tries = 0
local waitForWifi
waitForWifi = function()
    local wifi_on = NetworkMgr:isWifiOn()
    local connected = NetworkMgr:isConnected()
    if wifi_on and connected then
        logger.info(LOG, "Wi-Fi up after", wifi_tries, "s")
        runCycle()
        return
    end
    wifi_tries = wifi_tries + 1
    if wifi_tries % 5 == 0 then
        logger.info(LOG, "wifi wait", wifi_tries, "s, radio:", tostring(wifi_on), "connected:", tostring(connected))
    end
    -- escalation ladder, seconds hardcoded (see comment above danceResuspend)
    if wifi_tries == 4 then
        tryWpaCli("reassociate")
    elseif wifi_tries == 7 then
        tryUdhcpc()
    elseif wifi_tries >= 12 then
        logger.info(LOG, "quiet methods failed - brief wake to connect (dance)")
        dance = true
        dance_polls = 0
        dance_started = os.time()
        -- keep showing the wallpaper instead of the book while awake;
        -- "ui" = no flash, the content is identical to the current screen
        pcall(redrawSleepScreen, "ui")
        UIManager:scheduleIn(1, danceResuspend)
        Device.powerd:toggleSuspend()
        -- no light flash at night (frontlight restores on resume)
        UIManager:scheduleIn(1, function()
            pcall(function() Device.powerd:turnOffFrontlight() end)
        end)
        return -- the re-suspend runs the normal refresh and re-arms the alarm
    end
    UIManager:scheduleIn(1, waitForWifi)
end

wakeupCallback = function()
    local ok, err = pcall(function()
        logger.info(LOG, "RTC wake cycle")
        if lfs.attributes(NOWAKE_FILE, "mode") == "file" then
            logger.info(LOG, "nowake flag present, not rescheduling")
            return
        end
        wifi_tries = 0
        if NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
            runCycle()
        else
            NetworkMgr:restoreWifiAsync()
            requestAssociation()
            UIManager:scheduleIn(1, waitForWifi)
        end
    end)
    if not ok then
        logger.info(LOG, "wake cycle error, not rescheduling:", tostring(err))
    end
end

-- Start Wi-Fi as early as possible on an RTC wake: our callback only runs
-- ~15 s after wakeup (KindlePowerD:checkUnexpectedWakeup), so kicking the
-- radio at wakeupFromSuspend gives association a head start. Guarded to
-- wakes near our alarm time (random framework wakes happen several times a
-- day and shouldn't cost a Wi-Fi power-up) while the device stays asleep.
if Device.wakeup_mgr and Device.powerd and Device.powerd.wakeupFromSuspend then
    local orig_wakeup = Device.powerd.wakeupFromSuspend
    Device.powerd.wakeupFromSuspend = function(self, ...)
        pcall(function()
            if not Device.wakeup_mgr:isWakeupAlarmScheduled() then return end
            local task = Device.wakeup_mgr._task_queue and Device.wakeup_mgr._task_queue[1]
            -- 90 s matches KOReader's own wakeupAction proximity window
            if task and task.epoch and math.abs(os.time() - task.epoch) > 90 then return end
            local state = self.getPowerdState and self:getPowerdState() or nil
            if state == "screenSaver" or state == "suspended" then
                logger.info(LOG, "early Wi-Fi restore on RTC wake")
                NetworkMgr:restoreWifiAsync()
                -- give the radio a moment, then explicitly ask for association
                UIManager:scheduleIn(2, requestAssociation)
            end
        end)
        return orig_wakeup(self, ...)
    end
end

-- ---- hooks ----

local orig_setup = Screensaver.setup
Screensaver.setup = function(self, ...)
    dance = false -- a suspend ends any dance; kills revived stale timers
    pcall(refresh)
    pcall(scheduleWakeup)
    return orig_setup(self, ...)
end

-- Called by Kindle:outofScreenSaver on a user wake (not on RTC wakes): drop
-- the overlay and cancel the pending scheduled refresh.
local orig_close = Screensaver.close
Screensaver.close = function(self, ...)
    -- during the dance the overlay must stay: it hides the book while the
    -- device is briefly active
    if overlay and not dance then
        UIManager:close(overlay)
        overlay = nil
    end
    if Device.wakeup_mgr then
        Device.wakeup_mgr:removeTasks(nil, wakeupCallback)
        if not dance then
            logger.info(LOG, "user wake, cancelled scheduled refresh")
        end
    end
    return orig_close(self, ...)
end
