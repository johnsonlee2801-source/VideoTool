-- Tiny test harness: no dependencies, runs under luajit / lua 5.1.
local M = { passed = 0, failed = 0, failures = {} }

local function fmt(v)
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(x) end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(v)
end

function M.eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s\n    expected: %s\n    actual:   %s", msg or "eq", fmt(expected), fmt(actual)), 2)
    end
end

function M.near(actual, expected, eps, msg)
    if type(actual) ~= "number" or math.abs(actual - expected) > (eps or 1e-9) then
        error(string.format("%s\n    expected: %s (±%s)\n    actual:   %s", msg or "near", fmt(expected), fmt(eps or 1e-9), fmt(actual)), 2)
    end
end

function M.truthy(v, msg)
    if not v then error((msg or "truthy") .. "\n    got: " .. fmt(v), 2) end
end

function M.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        M.passed = M.passed + 1
        io.write("  ok   ", name, "\n")
    else
        M.failed = M.failed + 1
        M.failures[#M.failures + 1] = name .. ": " .. tostring(err)
        io.write("  FAIL ", name, "\n       ", tostring(err):gsub("\n", "\n       "), "\n")
    end
end

function M.report()
    io.write(string.format("\n%d passed, %d failed\n", M.passed, M.failed))
    if M.failed > 0 then os.exit(1) end
end

return M
