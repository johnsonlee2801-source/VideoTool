-- Minimal stand-in for mpv's `mp` and `mp.options` modules, enough to load and
-- drive main.lua headlessly. Nothing here is async: tests call fire_timers().
local F = {}

function F.new()
    local mp = {
        time = 0,
        props = { speed = 1.0, pause = false, ["mouse-pos"] = { x = 500, y = 300, hover = true } },
        bindings = {}, events = {}, timers = {}, commands = {}, osd_messages = {},
        overlays = {},
        option_overrides = {},   -- what read_options will inject
    }
    function mp.get_time() return mp.time end
    function mp.get_property_number(name, def) local v = mp.props[name]; if v == nil then return def end; return v end
    function mp.get_property_bool(name, def) local v = mp.props[name]; if v == nil then return def end; return v end
    function mp.get_property_native(name, def) local v = mp.props[name]; if v == nil then return def end; return v end
    function mp.set_property_number(name, v) mp.props[name] = v end
    function mp.set_property_bool(name, v) mp.props[name] = v end
    function mp.commandv(...) mp.commands[#mp.commands + 1] = { ... } end
    function mp.osd_message(text, dur) mp.osd_messages[#mp.osd_messages + 1] = { text, dur } end
    function mp.add_forced_key_binding(key, name, fn, flags)
        mp.bindings[key] = { name = name, fn = fn, flags = flags or {} }
    end
    function mp.register_event(name, fn) mp.events[name] = fn end
    function mp.add_periodic_timer(interval, fn)
        local t = { interval = interval, fn = fn, alive = true, periodic = true }
        function t:kill() self.alive = false end
        mp.timers[#mp.timers + 1] = t
        return t
    end
    function mp.add_timeout(delay, fn)
        local t = { interval = delay, fn = fn, alive = true, periodic = false }
        function t:kill() self.alive = false end
        mp.timers[#mp.timers + 1] = t
        return t
    end
    function mp.create_osd_overlay(fmt)
        local ov = { format = fmt, data = "", updates = 0, removed = 0, visible = false }
        function ov:update() self.updates = self.updates + 1; self.visible = true end
        function ov:remove() self.removed = self.removed + 1; self.visible = false end
        mp.overlays[#mp.overlays + 1] = ov
        return ov
    end
    -- test helpers
    function mp.fire_timers()
        for _, t in ipairs(mp.timers) do
            if t.alive then t.fn(); if not t.periodic then t.alive = false end end
        end
    end
    function mp.live_timers()
        local n = 0
        for _, t in ipairs(mp.timers) do if t.alive then n = n + 1 end end
        return n
    end
    function mp.press(key, event, canceled) mp.bindings[key].fn({ event = event, key_name = key, canceled = canceled or false }) end

    local options = {
        read_options = function(tbl, name)
            for k, v in pairs(mp.option_overrides) do tbl[k] = v end
        end,
    }
    return mp, options
end

-- Load main.lua fresh with this fake installed as `mp` / `mp.options`.
function F.load_adapter(mp, options, script_dir)
    package.loaded["mp"] = mp
    package.loaded["mp.options"] = options
    mp.log_lines = mp.log_lines or {}
    local function logger(level) return function(...) mp.log_lines[#mp.log_lines + 1] = level .. ": " .. table.concat({ ... }, " ") end end
    package.loaded["mp.msg"] = { info = logger("info"), warn = logger("warn"), error = logger("error"), debug = logger("debug"), verbose = logger("verbose") }
    package.loaded["gesture"] = nil
    local saved = package.path
    package.path = script_dir .. "/?.lua;" .. package.path
    local chunk = assert(loadfile(script_dir .. "/main.lua"))
    local ok, err = pcall(chunk)
    package.path = saved
    package.loaded["mp"] = nil
    package.loaded["mp.options"] = nil
    package.loaded["mp.msg"] = nil
    if not ok then error(err, 0) end
end

return F
