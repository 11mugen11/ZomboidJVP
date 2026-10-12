-- Verify actual item construction, not only vehicle/model registration.
-- These temporary probes are not placed in any inventory or in the world.
EmreRE9 = EmreRE9 or {}
local ids = {"Tire", "SupportTire", "GasTank", "Seat", "Muffler"}
local tag = "[EmreRE9 0.2.15] "

function EmreRE9.CheckPartItems()
    if not instanceItem then
        print(tag .. "Part check unavailable: instanceItem missing")
        return
    end
    local passed = 0
    for _, name in ipairs(ids) do
        local id = "EmreRE9." .. name
        local ok, result = pcall(instanceItem, id)
        if ok and result then
            passed = passed + 1
            print(tag .. "item " .. id .. "=true")
        else
            print(tag .. "item " .. id .. "=false; " .. tostring(result))
        end
    end
    print(tag .. "constructible parts=" .. tostring(passed) .. "/" .. tostring(#ids))
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(EmreRE9.CheckPartItems)
end
