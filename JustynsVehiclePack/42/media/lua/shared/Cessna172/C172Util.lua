--[[
    C172Util - shared helpers for identifying this aircraft and reading/writing its
    flight state. Independent copy of the pattern the MiG-29 and VX-9 mods each use;
    see C172Config.lua's header for why this is a full standalone copy rather than a
    shared file.
]]

require "Cessna172/C172Config"

C172Util = C172Util or {}

local DEFAULT_STATE = {
    altitude = 0,
    mode = "GROUND",
}

-- Returns the C172Config entry for this vehicle, or nil if it is not this aircraft.
-- This is THE identity gate for the whole mod - every entry point calls it first.
function C172Util.getConfig(vehicle)
    if not vehicle then return nil end
    local ok, scriptName = pcall(function() return vehicle:getScriptName() end)
    if not ok or not scriptName then return nil end
    return C172Config.get(scriptName)
end

function C172Util.isAircraft(vehicle)
    return C172Util.getConfig(vehicle) ~= nil
end

-- Persisted (save-game) flight state. Kept under a mod-unique key on the vehicle's own
-- modData so it cannot collide with the MiG's JetFlightData or the Wraith's own key.
function C172Util.getFlightState(vehicle)
    local data = vehicle:getModData()
    if not data.C172FlightData then
        data.C172FlightData = {
            altitude = DEFAULT_STATE.altitude,
            mode = DEFAULT_STATE.mode,
        }
    end
    return data.C172FlightData
end

function C172Util.setFlightState(vehicle, altitude, mode)
    local state = C172Util.getFlightState(vehicle)
    state.altitude = altitude
    state.mode = mode
    return state
end

return C172Util
