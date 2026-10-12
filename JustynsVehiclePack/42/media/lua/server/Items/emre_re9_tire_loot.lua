require "Items/ProceduralDistributions"

-- Keep the historical filename so upgrades cannot load two loot injectors.
-- RE9 physical spares only: the hidden SupportTire must never be loot.
EmreRE9PartLoot = EmreRE9PartLoot or {nativeEntries={}}
local L = EmreRE9PartLoot
local multipliers = {0.35, 1.0, 3.0}
local custom = {
    ["EmreRE9.Tire"]=true, ["EmreRE9.GasTank"]=true,
    ["EmreRE9.Seat"]=true, ["EmreRE9.Muffler"]=true,
}
L.additions = {
    MechanicShelfWheels = {"EmreRE9.Tire",8},
    CarTiresNormal3 = {"EmreRE9.Tire",5},
    MechanicShelfMufflers = {"EmreRE9.Muffler",6},
    CarMufflerNormal3 = {"EmreRE9.Muffler",5},
    MechanicShelfTools = {"EmreRE9.GasTank",3,"EmreRE9.Seat",3,"EmreRE9.Muffler",1},
    ToolCabinetMechanics = {"EmreRE9.GasTank",2,"EmreRE9.Seat",2},
    MechanicShelfElectric = {"Base.CarBattery3",6,"Base.CarBatteryCharger",3,
                            "Base.LightBulb",2,"Base.EngineParts",2},
    MechanicShelfBrakes = {"Base.NormalBrake3",6},
    MechanicShelfSuspension = {"Base.NormalSuspension3",6},
    GarageTools = {"EmreRE9.Tire",1.5,"EmreRE9.Seat",1},
    GarageMechanics = {"EmreRE9.Tire",4,"EmreRE9.GasTank",3,
                       "EmreRE9.Seat",3,"EmreRE9.Muffler",3,
                       "Base.CarBattery3",2,"Base.CarBatteryCharger",1,
                       "Base.NormalBrake3",2,"Base.NormalSuspension3",2,
                       "Base.EngineParts",2,"Base.LightBulb",1},
    CrateMechanics = {"EmreRE9.Tire",5,"EmreRE9.GasTank",3,
                      "EmreRE9.Seat",3,"EmreRE9.Muffler",3,
                      "Base.CarBattery3",2,"Base.CarBatteryCharger",1,
                      "Base.NormalBrake3",2,"Base.NormalSuspension3",2,
                      "Base.EngineParts",2,"Base.LightBulb",1},
}

local function fullType(id)
    if type(id) ~= "string" then return id end
    if not id:find(".",1,true) then return "Base." .. id end
    return id
end

local function clearOwnedNative()
    for _,entry in ipairs(L.nativeEntries) do
        local items = entry.items
        for i=#items-1,1,-2 do
            if items[i] == entry.id and items[i+1] == entry.weight then
                table.remove(items,i+1); table.remove(items,i)
                break
            end
        end
    end
    L.nativeEntries = {}
end

function L.apply()
    clearOwnedNative()
    local pools = ProceduralDistributions and ProceduralDistributions.list
    if type(pools) ~= "table" then return 0 end
    local options = SandboxVars and SandboxVars.EmreRE9 or {}
    local enabled = options.EnablePartLoot ~= false
    local multiplier = multipliers[tonumber(options.PartsFrequency)] or 1.0
    local count = 0
    for name, entries in pairs(L.additions) do
        local pool = pools[name]
        if type(pool) == "table" and type(pool.items) == "table" and #pool.items%2 == 0 then
            local items = pool.items
            -- Own IDs can be rebuilt safely when world options become available.
            for i=#items-1,1,-2 do
                if custom[fullType(items[i])] then
                    table.remove(items,i+1); table.remove(items,i)
                end
            end
            if enabled then
                local present = {}
                for i=1,#items,2 do present[fullType(items[i])] = true end
                for i=1,#entries,2 do
                    local id, weight = entries[i], entries[i+1]
                    if not present[id] then
                        if custom[id] then weight = weight*multiplier end
                        table.insert(items,id); table.insert(items,weight)
                        present[id] = true
                        if not custom[id] then
                            -- Only supplements created by this module are removed
                            -- on reapply. Existing native weights stay untouched.
                            L.nativeEntries[#L.nativeEntries+1] = {items=items,id=id,weight=weight}
                        end
                    end
                end
            end
            count = count+1
        end
    end
    return count
end

L.apply()
if not L.registered then
    L.registered = true
    Events.OnPreDistributionMerge.Add(function()
        local count = L.apply()
        local options = SandboxVars and SandboxVars.EmreRE9 or {}
        print("[EmreRE9 0.2.15] spare-part pools=" .. tostring(count)
            .. " enabled=" .. tostring(options.EnablePartLoot ~= false)
            .. " frequency=" .. tostring(options.PartsFrequency or 2))
    end)
end
return L
