-- Minimal test runner: luajit tests/run.lua  (from the repo root)
package.path = './?.lua;./?/init.lua;' .. package.path

local files = { 'tests.test_colony', 'tests.test_terrain', 'tests.test_defense', 'tests.test_supply', 'tests.test_schedule' }
local passed, failed = 0, 0

_G.test = function(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write('FAIL ', name, '\n', tostring(err), '\n\n')
    end
end

_G.eq = function(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%sexpected %s, got %s', msg and (msg .. ': ') or '',
            tostring(expected), tostring(actual)), 2)
    end
end

_G.near = function(actual, expected, tol, msg)
    if math.abs(actual - expected) > (tol or 1e-6) then
        error(string.format('%sexpected ~%s, got %s', msg and (msg .. ': ') or '',
            tostring(expected), tostring(actual)), 2)
    end
end

for _, f in ipairs(files) do require(f) end
io.write(string.format('%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
