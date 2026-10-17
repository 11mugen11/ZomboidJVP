-- Shared behavior registry for both adventure motorcycles.
EmreRE9 = EmreRE9 or {}
local R = {}
EmreRE9.Bikes = R
R.profiles = {
    ["Base.EMRE_RE9"] = {normal="Base.EMRE_RE9", mounted="Base.EMRE_RE9Carrier"},
    ["Base.JVP_Tenere"] = {normal="Base.JVP_Tenere", mounted="Base.JVP_TenereCarrier", aircraft="Base.JVP_TenereAircraft"},
}
R.profiles["Base.EMRE_RE9Carrier"] = R.profiles["Base.EMRE_RE9"]
R.profiles["Base.JVP_TenereCarrier"] = R.profiles["Base.JVP_Tenere"]
R.profiles["Base.JVP_TenereAircraft"] = R.profiles["Base.JVP_Tenere"]
function R.IsNormal(name)
    local p = R.profiles[name]
    return p ~= nil and name == p.normal
end
function R.IsMounted(name)
    local p = R.profiles[name]
    return p ~= nil and (name == p.mounted or name == p.aircraft)
end
return R
