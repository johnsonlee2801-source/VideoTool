-- hold-drag-speed/main.lua  (mpv adapter; logic lives in gesture.lua)
--
-- Hold the left mouse button on the video: playback jumps to hold_speed.
-- While holding, drag right to go faster and left to go slower.
-- Release: speed returns to what it was before the hold.
-- A short tap still toggles pause.
-- Tuning: script-opts/hold-drag-speed.conf

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"
local G = require "gesture"

local raw = {}
for k, v in pairs(G.defaults) do raw[k] = v end
options.read_options(raw, "hold-drag-speed")
local o = G.options(raw)

local POLL_INTERVAL = 1 / 60
local overlay = mp.create_osd_overlay("ass-events")

local function render(speed, dx)
    local arrow = speed > 1.0 and "▶▶" or (speed < 1.0 and "◀◀" or "▶")
    local bar_len = 24
    local pos = (speed - o.min_speed) / (o.max_speed - o.min_speed)
    local idx = math.floor(pos * (bar_len - 1) + 0.5)
    local cells = {}
    for i = 0, bar_len - 1 do cells[#cells + 1] = (i == idx) and "●" or "─" end
    overlay.data = string.format(
        "{\\an8\\fs56\\bord3}%s %.1fx\\N{\\fs30\\bord2}%s\\N{\\fs22\\bord2}drag %+dpx",
        arrow, speed, table.concat(cells), math.floor(dx + 0.5))
    overlay:update()
end

local io = {
    get_speed    = function() return mp.get_property_number("speed", 1.0) end,
    set_speed    = function(v) mp.set_property_number("speed", v) end,
    is_paused    = function() return mp.get_property_bool("pause", false) end,
    set_pause    = function(b) mp.set_property_bool("pause", b) end,
    toggle_pause = function() mp.commandv("cycle", "pause") end,
    show         = render,
    hide         = function() overlay:remove() end,
    -- mouse-pos is in backing pixels; divide by the HiDPI scale so the tuning
    -- numbers are in points and carry over to the Swift app unchanged.
    mouse_x      = function()
        local p = mp.get_property_native("mouse-pos")
        if not p or p.x == nil then return nil end
        local scale = mp.get_property_number("display-hidpi-scale", 1) or 1
        if scale <= 0 then scale = 1 end
        return p.x / scale
    end,
}

local machine = G.new(o, io)
local timer = nil

local function stop_timer()
    if timer then timer:kill(); timer = nil end
end

local function on_button(e)
    local now = mp.get_time()
    msg.info(string.format("event=%s canceled=%s holding=%s speed=%s mouse=%s",
        tostring(e.event), tostring(e.canceled), tostring(machine:is_holding()),
        tostring(mp.get_property_number("speed")), tostring(io.mouse_x())))
    if e.event == "down" then
        machine:on_down(now)
        stop_timer()
        timer = mp.add_periodic_timer(POLL_INTERVAL, function() machine:on_tick(mp.get_time()) end)
    elseif e.event == "up" then
        stop_timer()
        if e.canceled then
            -- A key press or focus loss took the button away: not a tap.
            machine:on_cancel()
            return
        end
        local was_holding = machine:is_holding()
        machine:on_up(now)
        if was_holding then
            mp.osd_message(string.format("▶ %.1fx", mp.get_property_number("speed", 1.0)), 0.6)
        end
    elseif e.event == "press" then
        -- mpv could not deliver down/up separately: treat as a tap.
        machine:on_down(now)
        machine:on_up(now)
    end
end

mp.add_forced_key_binding("MBTN_LEFT", "hold-drag-speed", on_button, { complex = true })
-- Swallow the double-click binding; otherwise tap-then-hold flips fullscreen.
mp.add_forced_key_binding("MBTN_LEFT_DBL", "hold-drag-speed-dbl", function() end)

mp.register_event("end-file", function()
    stop_timer()
    machine:on_file_end()
end)
