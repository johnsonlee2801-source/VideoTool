-- Fake of the io table the gesture machine talks to. Records every call.
local F = {}
F.__index = F

function F.new(initial)
    local self = setmetatable({}, F)
    self.speed = (initial and initial.speed) or 1.0
    self.paused = (initial and initial.paused) or false
    self.x = (initial and initial.x) or 500
    self.calls = {}
    self.set_speed_count = 0
    self.toggle_count = 0
    self.show_count = 0
    self.hide_count = 0
    self.last_show = nil
    return self
end

function F:log(name, ...) self.calls[#self.calls + 1] = { name, ... } end

function F:io()
    local s = self
    return {
        get_speed    = function() return s.speed end,
        set_speed    = function(v) s.set_speed_count = s.set_speed_count + 1; s.speed = v; s:log("set_speed", v) end,
        is_paused    = function() return s.paused end,
        set_pause    = function(b) s.paused = b; s:log("set_pause", b) end,
        toggle_pause = function() s.toggle_count = s.toggle_count + 1; s.paused = not s.paused; s:log("toggle_pause") end,
        show         = function(speed, dx) s.show_count = s.show_count + 1; s.last_show = { speed = speed, dx = dx }; s:log("show", speed, dx) end,
        hide         = function() s.hide_count = s.hide_count + 1; s:log("hide") end,
        mouse_x      = function() return s.x end,
    }
end

return F
