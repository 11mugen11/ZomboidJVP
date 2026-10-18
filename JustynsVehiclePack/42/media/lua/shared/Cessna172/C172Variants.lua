-- Exact whitelist: paint variants share flight systems, never other aircraft.
C172Variants = {}
local V=C172Variants
V.ids={"Base.Cessna172","Base.Cessna172Blue","Base.Cessna172Green","Base.Cessna172Yellow"}
V.colors={ ["Base.Cessna172"]="", ["Base.Cessna172Blue"]="Blue",
    ["Base.Cessna172Green"]="Green", ["Base.Cessna172Yellow"]="Yellow" }
function V.isName(name) return name~=nil and V.colors[name]~=nil end
function V.isVehicle(v) return v~=nil and V.isName(v:getScriptName()) end
function V.model(v,base) return base..(V.colors[v:getScriptName()] or "") end

-- The original contact controller toggles all Cessnas together. Keep the same
-- behavior for the three additional, otherwise identical VehicleScripts.
function V.footprints(small,full,clear)
    if not ScriptManager or not ScriptManager.instance then return end
    for _,id in ipairs(V.ids) do
        local script=ScriptManager.instance:getVehicle(id)
        if script then
            local e=script:getExtents()
            if small then e:set(clear,full[2],clear)
            else e:set(full[1],full[2],full[3]) end
        end
    end
end
return V
