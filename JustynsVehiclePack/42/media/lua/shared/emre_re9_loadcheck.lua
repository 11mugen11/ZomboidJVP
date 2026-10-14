-- Report actual registration once a saved game has started.
EmreRE9 = EmreRE9 or {}
local tag = "[EmreRE9 0.2.15] "
print(tag .. "Lua loaded")

function EmreRE9.CheckRegistration()
    if not ScriptManager or not ScriptManager.instance then
        print(tag .. "ScriptManager unavailable")
        return
    end
    local ok, vehicle, model = pcall(function()
        local manager = ScriptManager.instance
        return manager:getVehicle("Base.EMRE_RE9") ~= nil,
               manager:getModelScript("Base.EMRE_RE9Body") ~= nil
    end)
    if not ok then
        print(tag .. "Registration check failed: " .. tostring(vehicle))
        return
    end
    print(tag .. "vehicle Base.EMRE_RE9=" .. tostring(vehicle)
        .. "; body model=" .. tostring(model))
    local manager = ScriptManager.instance
    print("[JVP 1.0.8] Yamaha Tenere vehicle=" .. tostring(manager:getVehicle("Base.JVP_Tenere") ~= nil)
        .. "; carrier=" .. tostring(manager:getVehicle("Base.JVP_TenereCarrier") ~= nil)
        .. "; model=" .. tostring(manager:getModelScript("Base.JVP_TenereBody") ~= nil))
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(EmreRE9.CheckRegistration)
end
