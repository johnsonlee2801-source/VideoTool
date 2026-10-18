-- tests/live/driver.lua
-- In-process integration test: loaded into a real headless mpv next to the
-- hold-drag-speed script (see tests/live.sh). Replays the gesture through
-- mpv's own input pipeline (keydown / keyup / keypress / mouse commands),
-- reads back properties, logs "[live] ok|FAIL ..." lines and quits with
-- exit code 1 on any failure.

local mp = require "mp"
local msg = require "mp.msg"

local results = {}
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end
local function check(name, cond, detail)
    results[#results + 1] = cond
    msg.info(string.format("[live] %s %s   %s", cond and "ok  " or "FAIL", name, detail or ""))
end
local function speed() return mp.get_property_number("speed") end
local function paused() return mp.get_property_bool("pause") end
local function state() return string.format("speed=%s pause=%s", tostring(speed()), tostring(paused())) end

local steps = {}
local function step(delay, fn) steps[#steps + 1] = { delay = delay, fn = fn } end

-- setup
step(0.2, function()
    mp.set_property_bool("pause", false); mp.set_property_number("speed", 1.0)
    mp.commandv("mouse", 500, 300)
end)
step(0.1, function()
    local p = mp.get_property_native("mouse-pos")
    check("R0 mouse-pos readable after `mouse` command", p and p.x == 500, p and ("x=" .. tostring(p.x)) or "nil")
end)
-- R1..R4 hold, drag, release
step(0.05, function() mp.commandv("keydown", "MBTN_LEFT") end)
step(0.45, function() check("R1 hold -> 2.0x", near(speed(), 2.0), state()) end)
step(0.05, function() mp.commandv("mouse", 580, 300) end)
step(0.15, function() check("R2 drag +80px -> 2.4x", near(speed(), 2.4), state()) end)
step(0.05, function() mp.commandv("mouse", 400, 300) end)
step(0.15, function() check("R3 drag -100px -> 1.5x", near(speed(), 1.5), state()) end)
step(0.05, function() mp.commandv("mouse", 800, 300) end)
step(0.15, function() check("R3b drag +300px -> 3.9x (fast stage)", near(speed(), 3.9), state()) end)
step(0.05, function() mp.commandv("mouse", 1100, 300) end)
step(0.15, function() check("R3c drag +600px -> 6.0x cap", near(speed(), 6.0), state()) end)
step(0.05, function() mp.commandv("keyup", "MBTN_LEFT") end)
step(0.15, function() check("R4 release -> 1.0x, still playing", near(speed(), 1.0) and paused() == false, state()) end)
-- R5 tap
step(0.05, function() mp.commandv("keydown", "MBTN_LEFT") end)
step(0.08, function() mp.commandv("keyup", "MBTN_LEFT") end)
step(0.15, function() check("R5 tap -> paused, speed untouched", paused() == true and near(speed(), 1.0), state()) end)
-- R6 hold while paused
step(0.05, function() mp.commandv("keydown", "MBTN_LEFT") end)
step(0.45, function() check("R6a hold while paused -> playing at 2.0x", paused() == false and near(speed(), 2.0), state()) end)
step(0.05, function() mp.commandv("keyup", "MBTN_LEFT") end)
step(0.15, function() check("R6b release -> 1.0x, keeps playing", paused() == false and near(speed(), 1.0), state()) end)
-- R7 keyboard press during hold cancels the button
local r7_during, r7_after_key, r7_pause_after_key
step(0.05, function() mp.set_property_number("speed", 1.25) end)
step(0.05, function() mp.commandv("keydown", "MBTN_LEFT") end)
-- Real keyboards send separate down/up; only a key DOWN cancels the held
-- mouse binding (input.c: interpret_key -> release_down_cmd(ictx, true)).
-- A synthetic `keypress` does not, so do not "simplify" this to keypress.
step(0.45, function() r7_during = speed(); mp.commandv("keydown", "F12") end)
step(0.10, function() mp.commandv("keyup", "F12") end)
step(0.15, function() r7_after_key = speed(); r7_pause_after_key = paused(); mp.commandv("keyup", "MBTN_LEFT") end)
step(0.15, function()
    check("R7 key down during hold cancels: 1.25x restored at once, no pause toggle",
        near(r7_during, 2.0) and near(r7_after_key, 1.25) and r7_pause_after_key == false
        and near(speed(), 1.25) and paused() == false,
        string.format("during=%s after_key=%s pause_after_key=%s final %s",
            tostring(r7_during), tostring(r7_after_key), tostring(r7_pause_after_key), state()))
    mp.set_property_number("speed", 1.0)
end)
-- R8 double tap: fullscreen untouched, pause net unchanged
local fs0
step(0.05, function() fs0 = mp.get_property_bool("fullscreen"); mp.commandv("keydown", "MBTN_LEFT") end)
step(0.05, function() mp.commandv("keyup", "MBTN_LEFT") end)
step(0.05, function() mp.commandv("keydown", "MBTN_LEFT") end)
step(0.05, function() mp.commandv("keyup", "MBTN_LEFT") end)
step(0.25, function()
    check("R8 double tap: fullscreen unchanged, pause back to playing",
        mp.get_property_bool("fullscreen") == fs0 and paused() == false,
        string.format("fullscreen %s->%s %s", tostring(fs0), tostring(mp.get_property_bool("fullscreen")), state()))
end)
-- R9 new hold from a new origin
step(0.05, function() mp.commandv("mouse", 900, 300) end)
step(0.05, function() mp.commandv("keydown", "MBTN_LEFT") end)
step(0.45, function() check("R9a new hold starts at 2.0x from new origin", near(speed(), 2.0), state()) end)
step(0.05, function() mp.commandv("mouse", 820, 300) end)
step(0.15, function() check("R9b drag -80px -> 1.6x", near(speed(), 1.6), state()) end)
step(0.05, function() mp.commandv("keyup", "MBTN_LEFT") end)
step(0.15, function() check("R9c release -> 1.0x", near(speed(), 1.0), state()) end)
-- finish
step(0.1, function()
    local passed, failed = 0, 0
    for _, ok in ipairs(results) do if ok then passed = passed + 1 else failed = failed + 1 end end
    msg.info(string.format("[live] %d passed, %d failed", passed, failed))
    mp.commandv("quit", failed > 0 and 1 or 0)
end)

local i = 0
local function run_next()
    i = i + 1
    local s = steps[i]
    if not s then return end
    mp.add_timeout(s.delay, function() s.fn(); run_next() end)
end

mp.register_event("file-loaded", function()
    if i == 0 then run_next() end
end)
