-- Run from the repository root: lua tests/regressions.lua [suite [case]]
local H = dofile("tests/helpers.lua")
for _, suite in ipairs({ "triggers", "settings", "comms", "detection" }) do
    if not arg[1] or arg[1] == suite then
        dofile("tests/" .. suite .. ".lua")(H)
    end
end
assert(H.passed > 0, "unknown suite or case")
print("HeroHelper regressions passed (" .. H.passed .. " cases)")
