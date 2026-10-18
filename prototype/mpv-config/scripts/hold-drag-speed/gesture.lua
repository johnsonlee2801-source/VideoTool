-- gesture.lua
-- Pure logic for the hold-and-drag speed gesture. No mpv calls in here.
-- The mpv adapter (main.lua) feeds it time, button events and an io table;
-- the Swift app will port this file and its tests one to one.

local G = {}

G.defaults = {
    hold_threshold     = 0.25, -- seconds before a press counts as a hold
    hold_speed         = 2.0,  -- speed when the hold is recognised, drag origin
    px_per_tenth       = 20,   -- slow stage: points per 0.1x (both directions)
    boost_from_speed   = 3.0,  -- right of this speed the fast stage takes over
    px_per_tenth_fast  = 10,   -- fast stage: points per 0.1x
    deadzone_px        = 8,    -- ignored movement around the origin
    min_speed          = 0.5,
    max_speed          = 6.0,
    snap_tenths        = 1,    -- 1: round to 0.1 steps, 0: continuous
    restore_on_release = 1,    -- 1: restore pre-hold speed, 0: keep dragged speed
}
-- Default curve, right of the origin (after the 8 pt deadzone):
--   2.0x --(200 pt, 20 pt per 0.1x)--> 3.0x --(300 pt, 10 pt per 0.1x)--> 6.0x
-- Left of the origin: 20 pt per 0.1x down to 0.5x (150 pt).

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function number_or(v, fallback)
    if type(v) == "number" and v == v and v > -math.huge and v < math.huge then return v end
    return fallback
end

-- Build a validated options table from user overrides. Never mutates defaults.
function G.options(overrides)
    local d, o = G.defaults, {}
    for k, v in pairs(d) do o[k] = v end
    for k, v in pairs(overrides or {}) do
        if d[k] ~= nil then o[k] = number_or(v, d[k]) end
    end
    if o.px_per_tenth <= 0 then o.px_per_tenth = d.px_per_tenth end
    if o.px_per_tenth_fast <= 0 then o.px_per_tenth_fast = d.px_per_tenth_fast end
    if o.deadzone_px < 0 then o.deadzone_px = d.deadzone_px end
    if o.hold_threshold < 0 then o.hold_threshold = d.hold_threshold end
    if not (o.min_speed > 0 and o.min_speed < o.max_speed) then
        o.min_speed, o.max_speed = d.min_speed, d.max_speed
    end
    o.hold_speed = clamp(o.hold_speed, o.min_speed, o.max_speed)
    -- Fast stage only makes sense between the hold speed and the cap;
    -- anything else disables it by moving the boost point to the cap.
    if not (o.boost_from_speed >= o.hold_speed and o.boost_from_speed <= o.max_speed) then
        o.boost_from_speed = o.max_speed
    end
    o.snap_tenths = (o.snap_tenths ~= 0) and 1 or 0
    o.restore_on_release = (o.restore_on_release ~= 0) and 1 or 0
    return o
end

-- Map horizontal drag distance (pixels, right positive) to playback speed.
function G.speed_for_drag(dx, o)
    o = o or G.defaults
    local dz = o.deadzone_px
    local effective = 0
    if dx > dz then effective = dx - dz elseif dx < -dz then effective = dx + dz end
    local speed
    -- Points needed to climb from hold_speed to the boost point on the slow slope.
    local slow_px = (o.boost_from_speed - o.hold_speed) * 10 * o.px_per_tenth
    if effective > slow_px then
        speed = o.boost_from_speed + ((effective - slow_px) / o.px_per_tenth_fast) * 0.1
    else
        speed = o.hold_speed + (effective / o.px_per_tenth) * 0.1
    end
    if o.snap_tenths == 1 then
        -- 1e-9 guards against 2.05*10 landing on 20.4999999 in binary floats.
        speed = math.floor(speed * 10 + 0.5 + 1e-9) / 10
    end
    return clamp(speed, o.min_speed, o.max_speed)
end

-- ------------------------------------------------------------------ machine
-- io contract (all functions):
--   get_speed() -> number        set_speed(number)
--   is_paused() -> boolean       set_pause(boolean)      toggle_pause()
--   show(speed, dx)              hide()                  mouse_x() -> number|nil

local Machine = {}
Machine.__index = Machine

function G.new(o, io)
    return setmetatable({
        o = o, io = io,
        pressed = false, holding = false,
        down_at = nil,
        start_x = nil,          -- first mouse sample seen during the hold
        saved_speed = 1.0, current = nil,
        shown_speed = nil, shown_dx = nil,
    }, Machine)
end

function Machine:is_holding() return self.holding end

function Machine:apply(speed)
    if speed ~= self.current then
        self.current = speed
        self.io.set_speed(speed)
    end
end

-- Redraw only when something visible changed (speed or the px read-out).
function Machine:draw(speed, dx)
    if speed ~= self.shown_speed or dx ~= self.shown_dx then
        self.shown_speed, self.shown_dx = speed, dx
        self.io.show(speed, dx)
    end
end

function Machine:begin_hold()
    self.holding = true
    self.start_x = self.io.mouse_x()        -- may be nil; first later sample wins
    self.saved_speed = self.io.get_speed()
    self.current = nil
    self.shown_speed, self.shown_dx = nil, nil
    -- Decision: a hold always moves forward, and release does not re-pause.
    if self.io.is_paused() then self.io.set_pause(false) end
    self:apply(self.o.hold_speed)
    self:draw(self.o.hold_speed, 0)
end

function Machine:end_hold()
    self.holding = false
    self.io.hide()
    if self.o.restore_on_release == 1 then self:apply(self.saved_speed) end
end

function Machine:on_down(now)
    if self.pressed then return end
    self.pressed = true
    self.down_at = now
end

function Machine:on_tick(now)
    if not self.pressed then return end
    if not self.holding then
        if now - self.down_at >= self.o.hold_threshold then self:begin_hold() end
        return
    end
    local x = self.io.mouse_x()
    if self.start_x == nil then self.start_x = x end
    local dx = 0
    if x ~= nil and self.start_x ~= nil then dx = x - self.start_x end
    self:apply(G.speed_for_drag(dx, self.o))
    self:draw(self.current, dx)
end

function Machine:on_up(now)
    if not self.pressed then return end
    self.pressed = false
    if self.holding then
        self:end_hold()
    else
        self.io.toggle_pause()
    end
end

-- The press was taken away from us (mpv cancels a held binding when a key is
-- pressed or the window loses focus, or the file ended). Never a tap.
function Machine:on_cancel()
    if self.holding then self:end_hold() end
    self.pressed = false
end

function Machine:on_file_end()
    self:on_cancel()
end

return G
