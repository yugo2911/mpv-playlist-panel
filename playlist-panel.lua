local mp      = require("mp")
local assdraw = require("mp.assdraw")
local opts    = require("mp.options")


-- ── User options ───────────────────────────────────────────────────────────

local o = {
    key_toggle = "Tab",   key_close  = "Escape",
    key_up     = "UP",    key_down   = "DOWN",
    key_select = "ENTER", key_cycle  = "c",

    max_rows   = 6,       thumb_seek = 10,     -- rows visible; seconds into file for thumb

    watched_pct      = 90,   watched_min_secs = 10,   -- % threshold; minimum playback secs
    watched_on_skip  = true,                          -- mark watched on skip / non-quit end

    marquee_delay = 1.2,  marquee_speed = 38,  marquee_gap = 50, -- sec; virt-px/s; virt-px

    watched_thumb_dim = 220,  -- brightness reduction for watched thumbnails (0=none, 255=black)
    watched_label_dim = true, -- dim text labels for watched entries
}
opts.read_options(o, "playlist-panel")


-- ── Constants ──────────────────────────────────────────────────────────────

local REF_W, REF_H            = 1280, 720
local ROW_H, THUMB_W, THUMB_H = 88, 136, 76
local HDR_H, CK_W, HANDLE_W   = 46, 32, 6

-- Panel width cycling: STEP_COUNT steps, each STEP_PCT of REF_W
local STEP_COUNT, STEP_PCT, panel_step = 3, 0.20, 2
local function panel_w() return math.floor(REF_W * panel_step * STEP_PCT) end


-- ── Resize debounce ────────────────────────────────────────────────────────
-- Fast drag (events < FAST_GAP_MS apart) → FAST_DB_MS; slow drag → SLOW_DB_MS.

local FAST_GAP_MS, FAST_DB_MS, SLOW_DB_MS    = 10, 100, 200
local debounce_timer, last_event_ms, resizing = nil, 0, false


-- ── Thumbnail dir ──────────────────────────────────────────────────────────

local is_windows = package.config:sub(1, 1) == "\\"
local THUMB_DIR  = (os.getenv("TEMP") or "/tmp") .. "/mpv-thumbs-" .. os.time() .. "/"


-- ── State ──────────────────────────────────────────────────────────────────

local visible, cursor, scroll, plist, current = false, 0, 0, {}, 0
local current_path   = nil  -- cached from file-loaded; safe to read in end-file
local thumb_cache    = {}
local duration_cache = {}

-- Track what is shown in each overlay slot; only call overlay-add on change.
local overlay_state = {}  -- overlay_state[row] = filepath or nil


-- ── Watched tracking ───────────────────────────────────────────────────────
-- Persisted as one absolute path per line in watched.json.
-- Two triggers: percent-pos threshold, and end-file (skip / natural EOF).

local WATCHED_FILE              = mp.command_native({"expand-path", "~~/watched.json"})
local watched                   = {}
local watched_threshold_crossed = false  -- true once % threshold crossed; avoids double-fire

local function watched_save()
    local f = io.open(WATCHED_FILE, "w")
    if not f then return end
    for path in pairs(watched) do f:write(path .. "\n") end
    f:close()
end

local function watched_load()
    local f = io.open(WATCHED_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local path = line:match("^%s*(.-)%s*$")
        if path ~= "" then watched[path] = true end
    end
    f:close()
end

watched_load()

local render  -- forward declaration

local function mark_watched(path)
    if not path or path == "" or watched[path] then return end

    local playback_time = mp.get_property_number("playback-time", 0)
    local duration      = mp.get_property_number("duration", 0)
    if playback_time < o.watched_min_secs or duration < o.watched_min_secs then return end

    watched[path] = true
    watched_save()
    if visible and not resizing and render then render() end
end

-- Trigger 1: percentage threshold crossed during normal playback.
mp.observe_property("percent-pos", "number", function(_, val)
    if val and val >= o.watched_pct then
        watched_threshold_crossed = true
        mark_watched(mp.get_property("path"))
    end
end)

-- Trigger 2: file ends for any reason except the user quitting mpv entirely.
-- Covers: natural EOF, playlist advance, loadfile, skip-to-next/prev.
mp.register_event("end-file", function(evt)
    if evt and evt.reason ~= "quit" then
        if o.watched_on_skip and current_path then mark_watched(current_path) end
    end
    current_path, watched_threshold_crossed = nil, false
end)


-- ── Marquee (scrolling title) ──────────────────────────────────────────────

local marquee_timer   = nil
local marquee_elapsed = 0   -- seconds since cursor last moved / panel opened
local marquee_offset  = 0   -- current horizontal scroll offset (virtual px)

local function marquee_stop()
    if marquee_timer then marquee_timer:kill(); marquee_timer = nil end
end

local function marquee_reset()
    marquee_stop()
    marquee_elapsed, marquee_offset = 0, 0
end

local function marquee_tick()
    local INTERVAL = 1 / 30
    marquee_elapsed = marquee_elapsed + INTERVAL
    if marquee_elapsed > o.marquee_delay then
        marquee_offset = marquee_offset + o.marquee_speed * INTERVAL
    end
    if visible and not resizing then render() end
    marquee_timer = mp.add_timeout(INTERVAL, marquee_tick)
end

local function marquee_start()
    marquee_reset()
    marquee_timer = mp.add_timeout(o.marquee_delay / 2, function()
        marquee_timer = mp.add_timeout(1 / 30, marquee_tick)
    end)
end


-- ── Helpers ────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function esc(s) return tostring(s):gsub("{", "\\{"):gsub("}", "\\}") end

local function fmt_time(s)
    if not s or s < 0 then return nil end
    local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
    return h > 0 and ("%d:%02d:%02d"):format(h, m, math.floor(s % 60))
                 or  ("%d:%02d"):format(m, math.floor(s % 60))
end

local function clean_name(path, idx, title)
    if title and title ~= "" then return title end
    if not path or path == "" then return "Episode " .. (idx + 1) end
    local name = path:match("([^/\\]+)$") or path
    name = name:gsub("%.[^%.]+$", "")
               :gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    for _ = 1, 3 do name = name:gsub("^%s*%b[]%s*", ""):gsub("^%s*%b()%s*", "") end
    for _ = 1, 6 do name = name:gsub("%s*%b[]%s*$", ""):gsub("%s*%b()%s*$", "") end
    name = name:gsub("[._]+", " "):gsub("%s*[-–—]%s*", " - "):match("^%s*(.-)%s*$")
    return name ~= "" and name or "Episode " .. (idx + 1)
end

local function parse_episode(path)
    if not path then return nil end
    local s = path:match("([^/\\]+)$") or path
    s = s:gsub("%.[^%.]+$", ""):gsub("%s*%b[]%s*", " "):gsub("%s*%b()%s*", " ")
         :gsub("%s+", " "):match("^%s*(.-)%s*$")
    local ep = s:match("[Ss]%d+[%s%._%-]*[Ee](%d+%.?%d*)")
            or s:match("%f[%a][Ee][Pp]%s*(%d+%.?%d*)%f[^%d]")
            or s:match("[%-%–—]%s*(%d+%.?%d*)%s*$")
            or s:match("%s(%d+%.?%d*)%s*$")
    local n = tonumber(ep)
    return (n and n >= 1 and n <= 9999) and ("EP %02d"):format(math.floor(n)) or nil
end

local function get_scale()
    local ww, wh = mp.get_osd_size()
    if not ww or ww == 0 then return 1, 1 end
    return ww / REF_W, wh / REF_H
end


-- ── Overlay management ─────────────────────────────────────────────────────

local function clear_thumb_overlays()
    for i = 0, o.max_rows + 1 do
        mp.command_native({name = "overlay-remove", id = i + 10})
        overlay_state[i] = nil
    end
end


-- ── Duration fetching ──────────────────────────────────────────────────────

local function fetch_duration(idx, path)
    if not path or path == "" then return end
    if duration_cache[path] then
        if plist[idx + 1] then plist[idx + 1].duration = duration_cache[path] end
        if visible and not resizing then render() end
        return
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = {"ffprobe", "-v", "quiet", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", path},
    }, function(_, res)
        if res and res.status == 0 and res.stdout then
            local d = tonumber(res.stdout:match("([%d%.]+)"))
            if d then
                duration_cache[path] = d
                if plist[idx + 1] then plist[idx + 1].duration = d end
                if visible and not resizing then render() end
            end
        end
    end)
end

local function prefetch_durations()
    for i = 0, #plist - 1 do
        if plist[i + 1] and not duration_cache[plist[i + 1].path] then
            fetch_duration(i, plist[i + 1].path)
        end
    end
end


-- ── Thumbnail generation ───────────────────────────────────────────────────
-- thumb_cache[idx]      = path to full-brightness .bgra
-- thumb_cache_dim[idx]  = path to pre-dimmed .bgra (watched entries)

local thumb_cache_dim = {}

-- Write a dimmed copy of a BGRA file by scaling RGB channels in Lua.
-- alpha_factor: 0.0 (black) – 1.0 (original).  Runs synchronously but the
-- files are small (272×152×4 = ~166 KB) so it's fast enough.
local function make_dimmed_bgra(src, dst, factor)
    local f = io.open(src, "rb")
    if not f then return false end
    local data = f:read("*a"); f:close()
    if #data ~= 272 * 152 * 4 then return false end
    local out = {}
    for i = 1, #data, 4 do
        local b = data:byte(i)   * factor
        local g = data:byte(i+1) * factor
        local r = data:byte(i+2) * factor
        local a = data:byte(i+3)
        out[#out+1] = string.char(math.floor(b), math.floor(g), math.floor(r), a)
    end
    local wf = io.open(dst, "wb")
    if not wf then return false end
    wf:write(table.concat(out)); wf:close()
    return true
end

local function gen_thumb(idx, path)
    if not path or path == "" or thumb_cache[idx] then return end
    local out = THUMB_DIR .. idx .. ".bgra"
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = {"ffmpeg", "-loglevel", "quiet", "-y",
                "-ss", tostring(o.thumb_seek), "-i", path, "-vframes", "1",
                "-vf", "scale=272:152:force_original_aspect_ratio=decrease,"
                    .. "pad=272:152:(ow-iw)/2:(oh-ih)/2,format=bgra",
                "-f", "rawvideo", out},
    }, function(_, res)
        if res and res.status == 0 then
            thumb_cache[idx] = out
            -- Pre-generate dimmed version (factor = 1 - dim_alpha/255)
            local dim_factor = 1.0 - clamp(o.watched_thumb_dim, 0, 255) / 255
            local dim_out    = THUMB_DIR .. idx .. "_dim.bgra"
            if make_dimmed_bgra(out, dim_out, dim_factor) then
                thumb_cache_dim[idx] = dim_out
            end
            if visible and not resizing then render() end
        end
    end)
end


-- ── Playlist refresh ───────────────────────────────────────────────────────

local function refresh()
    local n = mp.get_property_number("playlist-count", 0) or 0
    if n == 0 then plist = {}; current = 0; return end
    plist   = {}
    current = mp.get_property_number("playlist-pos", 0) or 0
    for i = 0, n - 1 do
        local path  = mp.get_property(("playlist/%d/filename"):format(i)) or ""
        local title = mp.get_property(("playlist/%d/title"):format(i))
        plist[i + 1] = {
            label    = clean_name(path, i, title),
            episode  = parse_episode(path),
            duration = duration_cache[path],
            path     = path,
        }
        gen_thumb(i, path)
        if not duration_cache[path] then fetch_duration(i, path) end
    end
end


-- ── Label width estimation ─────────────────────────────────────────────────
-- ASS \fs20 at REF_W: empirically ~11.2 px per character.

local FONT_PX_PER_CHAR = 11.2
local function estimate_label_w(label) return #label * FONT_PX_PER_CHAR end


-- ── Render ─────────────────────────────────────────────────────────────────

render = function()
    if not visible or #plist == 0 then
        clear_thumb_overlays(); mp.set_osd_ass(0, 0, "")
        return
    end

    local sw, sh = get_scale()
    local rows   = math.min(o.max_rows, #plist)
    local PW     = panel_w()
    local PX     = REF_W - PW - 40
    local PY     = math.max(40, math.floor(REF_H * 0.9) - (HDR_H + rows * ROW_H))
    local PX2    = PX + PW
    local PY2    = PY + HDR_H + rows * ROW_H

    local ass = assdraw.ass_new()

    -- Drop shadow
    ass:new_event(); ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H000000&\\1a&H80&}")
    ass:draw_start(); ass:rect_cw(PX + 6, PY + 6, PX2 + 6, PY2 + 6); ass:draw_stop()

    -- Main panel background
    ass:new_event(); ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H0F0F0F&\\1a&H10&}")
    ass:draw_start(); ass:rect_cw(PX, PY, PX2, PY2); ass:draw_stop()

    -- Header bar
    ass:new_event(); ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H0A0A0A&\\1a&H00&}")
    ass:draw_start(); ass:rect_cw(PX, PY, PX2, PY + HDR_H); ass:draw_stop()

    -- Left handle strip
    ass:new_event(); ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H2A2A2A&\\1a&H00&}")
    ass:draw_start(); ass:rect_cw(PX, PY, PX + HANDLE_W, PY2); ass:draw_stop()

    -- Handle grip dots (5 dots centred on the strip)
    local GX = PX + math.floor(HANDLE_W / 2)
    for di = -2, 2 do
        ass:new_event(); ass:pos(GX, math.floor((PY + PY2) / 2) + di * 8)
        ass:append("{\\an5\\bord0\\shad0\\fs6\\1c&H505050&}●")
    end

    -- Size indicator dots below header text
    local DX0 = PX + math.floor((PW - (STEP_COUNT - 1) * 12) / 2)
    for si = 1, STEP_COUNT do
        ass:new_event(); ass:pos(DX0 + (si - 1) * 12, PY + HDR_H - 8)
        ass:append(("{\\an5\\bord0\\shad0\\fs7\\1c&H%s&}●"):format(
            si == panel_step and "AAAAAA" or "333333"))
    end

    -- Header labels
    ass:new_event(); ass:pos(PX + 18, PY + HDR_H / 2)
    ass:append("{\\an4\\bord0\\shad0\\fs13\\1c&H999999&}EPISODES")
    ass:new_event(); ass:pos(PX2 - 16, PY + HDR_H / 2)
    ass:append(("{\\an6\\bord0\\shad0\\fs13\\1c&H333333&}%d / %d"):format(cursor + 1, #plist))

    -- Build map of which overlay file each visible row needs this frame.
    -- Watched non-current rows use the pre-dimmed BGRA if available.
    local needed = {}
    for row = 0, rows - 1 do
        local idx  = scroll + row
        local item = plist[idx + 1]
        if item and thumb_cache[idx] then
            local use_dim = item.path and watched[item.path] and idx ~= current
            needed[row]   = (use_dim and thumb_cache_dim[idx]) or thumb_cache[idx]
        end
    end

    -- Remove overlay slots no longer needed or whose file changed
    for row = 0, o.max_rows + 1 do
        if overlay_state[row] and overlay_state[row] ~= needed[row] then
            mp.command_native({name = "overlay-remove", id = row + 10})
            overlay_state[row] = nil
        end
    end

    -- ── Per-row drawing ───────────────────────────────────────────────────

    for row = 0, rows - 1 do
        local idx  = scroll + row
        local item = plist[idx + 1]
        if not item then break end

        local RY1 = PY + HDR_H + row * ROW_H
        local RY2 = RY1 + ROW_H

        -- Row divider
        if row > 0 then
            ass:new_event(); ass:pos(0, 0)
            ass:append("{\\an7\\bord0\\shad0\\1c&H151515&\\1a&H00&}")
            ass:draw_start(); ass:rect_cw(PX, RY1, PX2, RY1 + 1); ass:draw_stop()
        end

        -- Cursor highlight
        if idx == cursor then
            ass:new_event(); ass:pos(0, 0)
            ass:append("{\\an7\\bord0\\shad0\\1c&H181818&\\1a&H00&}")
            ass:draw_start(); ass:rect_cw(PX, RY1, PX2, RY2); ass:draw_stop()
            ass:new_event(); ass:pos(0, 0)
            ass:append("{\\an7\\bord0\\shad0\\1c&H666666&\\1a&H00&}")
            ass:draw_start(); ass:rect_cw(PX, RY1, PX + 3, RY2); ass:draw_stop()
        end

        local is_watched = item.path and item.path ~= "" and watched[item.path]
        local is_current = idx == current

        -- Playing dot or watched checkmark
        if is_current then
            ass:new_event(); ass:pos(PX + HANDLE_W + CK_W / 2, RY1 + ROW_H / 2)
            ass:append("{\\an5\\bord0\\shad0\\fs14\\1c&H77AA77&}●")
        elseif is_watched then
            ass:new_event(); ass:pos(PX + HANDLE_W + CK_W / 2, RY1 + ROW_H / 2)
            ass:append("{\\an5\\bord0\\shad0\\fs11\\1c&H336633&}✓")
        end

        -- Thumbnail coordinates
        local TX1 = PX + HANDLE_W + CK_W
        local TY1 = RY1 + math.floor((ROW_H - THUMB_H) / 2)
        local TX2 = TX1 + THUMB_W
        local TY2 = TY1 + THUMB_H

        if needed[row] then
            -- Issue overlay-add only when slot content is new
            if overlay_state[row] ~= needed[row] then
                mp.command_native({
                    name   = "overlay-add", id = row + 10,
                    x      = math.floor(TX1 * sw), y      = math.floor(TY1 * sh),
                    file   = needed[row],           offset = 0, fmt = "bgra",
                    w      = 272, h = 152,          stride = 272 * 4,
                    dw     = math.floor(THUMB_W * sw), dh = math.floor(THUMB_H * sh),
                })
                overlay_state[row] = needed[row]
            end
        else
            -- Placeholder box; darker shade for watched entries
            local ph_clr = is_watched and "111111" or "1A1A1A"
            ass:new_event(); ass:pos(0, 0)
            ass:append(("{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H00&}"):format(ph_clr))
            ass:draw_start(); ass:rect_cw(TX1, TY1, TX2, TY2); ass:draw_stop()
        end

        -- Label text area
        local LX   = TX2 + 16
        local LW   = PX2 - 16 - LX
        local CLIP = ("{\\clip(%d,%d,%d,%d)}"):format(LX, RY1 + 4, PX2 - 16, RY2 - 4)

        -- Colour: playing > cursor+watched > cursor > watched > normal
        local clr
        if     is_current                         then clr = "77AA77"
        elseif idx == cursor and is_watched       then clr = "888888"
        elseif idx == cursor                      then clr = "BBBBBB"
        elseif is_watched and o.watched_label_dim then clr = "404040"
        else                                           clr = "777777"
        end

        -- Marquee: scroll cursor-row label if it overflows the available width
        local label_esc = esc(item.label)
        if idx == cursor and estimate_label_w(item.label) > LW then
            local cycle = estimate_label_w(item.label) + o.marquee_gap
            local off   = marquee_offset % cycle
            ass:new_event(); ass:pos(LX - off, RY1 + 28)
            ass:append(("%s{\\an4\\bord0\\shad0\\fs20\\1c&H%s&}%s"):format(CLIP, clr, label_esc))
            ass:new_event(); ass:pos(LX - off + cycle, RY1 + 28)
            ass:append(("%s{\\an4\\bord0\\shad0\\fs20\\1c&H%s&}%s"):format(CLIP, clr, label_esc))
        else
            ass:new_event(); ass:pos(LX, RY1 + 28)
            ass:append(("%s{\\an4\\bord0\\shad0\\fs20\\1c&H%s&}%s"):format(CLIP, clr, label_esc))
        end

        -- Sub-line: episode tag + duration
        local sub     = (item.episode or "") .. (item.duration and "  ·  " .. fmt_time(item.duration) or "")
        local sub_clr = (is_watched and o.watched_label_dim) and "282828" or "444444"
        ass:new_event(); ass:pos(LX, RY1 + 60)
        ass:append(("%s{\\an4\\bord0\\shad0\\fs15\\1c&H%s&}%s"):format(CLIP, sub_clr, esc(sub)))
    end

    -- ── Scrollbar ─────────────────────────────────────────────────────────

    if #plist > rows then
        local SBH  = rows * ROW_H
        local SBY1 = PY + HDR_H
        local TH   = math.max(18, math.floor(SBH * rows / #plist))
        local TY   = SBY1 + math.floor(SBH * scroll / #plist)
        ass:new_event(); ass:pos(0, 0)
        ass:append("{\\an7\\bord0\\shad0\\1c&H121212&\\1a&H00&}")
        ass:draw_start(); ass:rect_cw(PX2 - 4, SBY1, PX2 - 2, SBY1 + SBH); ass:draw_stop()
        ass:new_event(); ass:pos(0, 0)
        ass:append("{\\an7\\bord0\\shad0\\1c&H303030&\\1a&H00&}")
        ass:draw_start(); ass:rect_cw(PX2 - 4, TY, PX2 - 2, TY + TH); ass:draw_stop()
    end

    mp.set_osd_ass(REF_W, REF_H, ass.text)
end


-- ── Panel size cycling ─────────────────────────────────────────────────────

local function cycle_size()
    panel_step = (panel_step % STEP_COUNT) + 1
    for i = 0, o.max_rows + 1 do
        mp.command_native({name = "overlay-remove", id = i + 10})
        overlay_state[i] = nil
    end
    render()
end


-- ── Panel toggle ───────────────────────────────────────────────────────────

local function toggle(force_close)
    if not force_close and not visible then
        local n = mp.get_property_number("playlist-count", 0) or 0
        if n == 0 then return end
    end

    visible = not (force_close or visible)
    if not visible then
        marquee_stop()
        clear_thumb_overlays(); mp.set_osd_ass(0, 0, "")
        for _, k in ipairs({"pp-up", "pp-down", "pp-select", "pp-close", "pp-cycle"}) do
            mp.remove_key_binding(k)
        end
        return
    end

    refresh()
    if #plist == 0 then visible = false; return end

    cursor = clamp(current, 0, #plist - 1)
    scroll = clamp(cursor - math.floor(o.max_rows / 2), 0, math.max(0, #plist - o.max_rows))
    marquee_start(); render()

    local function move(d)
        cursor = clamp(cursor + d, 0, #plist - 1)
        scroll = clamp(cursor - math.floor(o.max_rows / 2), 0, math.max(0, #plist - o.max_rows))
        marquee_start(); render()
    end

    mp.add_forced_key_binding(o.key_up,     "pp-up",     function() move(-1) end, {repeatable = true})
    mp.add_forced_key_binding(o.key_down,   "pp-down",   function() move( 1) end, {repeatable = true})
    mp.add_forced_key_binding(o.key_select, "pp-select", function()
        mp.set_property_number("playlist-pos", cursor); current = cursor; toggle(true)
    end)
    mp.add_forced_key_binding(o.key_close,  "pp-close",  function() toggle(true) end)
    mp.add_forced_key_binding(o.key_cycle,  "pp-cycle",  cycle_size)
end


-- ── Window resize debounce ─────────────────────────────────────────────────

mp.observe_property("osd-dimensions", "native", function()
    if not visible then return end
    local now_ms  = mp.get_time() * 1000
    local gap     = now_ms - last_event_ms
    last_event_ms = now_ms
    if not resizing then
        resizing = true
        clear_thumb_overlays(); mp.set_osd_ass(0, 0, "")
    end
    if debounce_timer then debounce_timer:kill(); debounce_timer = nil end
    local delay = (gap >= FAST_GAP_MS and SLOW_DB_MS or FAST_DB_MS) / 1000
    debounce_timer = mp.add_timeout(delay, function()
        debounce_timer, resizing = nil, false
        if visible then render() end
    end)
end)


-- ── File-loaded event ──────────────────────────────────────────────────────

mp.register_event("file-loaded", function()
    if #plist == 0 then refresh() end
    local path = mp.get_property("path")
    current_path, watched_threshold_crossed = path, false
    local dur = mp.get_property_number("duration")
    if dur and path then
        duration_cache[path] = dur
        if plist[current + 1] then plist[current + 1].duration = dur end
    end
    prefetch_durations()
    if visible then render() end
end)


-- ── Thumbnail dir setup / cleanup ──────────────────────────────────────────

local function run(args)
    mp.command_native({name = "subprocess", args = args, playback_only = false})
end

if is_windows then
    run({"cmd.exe", "/c", "mkdir", THUMB_DIR})
    mp.register_event("shutdown", function() run({"cmd.exe", "/c", "rmdir", "/s", "/q", THUMB_DIR}) end)
else
    run({"mkdir", "-p", THUMB_DIR})
    mp.register_event("shutdown", function() run({"rm", "-rf", THUMB_DIR}) end)
end


-- ── Key binding ────────────────────────────────────────────────────────────

mp.add_key_binding(o.key_toggle, "playlist-panel-toggle", toggle)