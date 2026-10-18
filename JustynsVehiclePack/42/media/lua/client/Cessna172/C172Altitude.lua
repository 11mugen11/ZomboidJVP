-- World-height flight commands. Surface probes affect landing only.
C172Altitude = C172Altitude or {}
local A = C172Altitude
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function A.cruiseVS(st, tune, engineOn)
    if not engineOn then return -tune.DESCEND_RATE end
    local height = (st.flightBaseH or 0) + (st.gearDatum or 0)
                 + st.altitude * tune.LIFT_HEIGHT_SCALE
    -- Proportional capture eases to level flight instead of overshooting the cruise.
    return clamp((tune.CRUISE_BODY_H - height) / tune.LIFT_HEIGHT_SCALE,
                 -tune.DESCEND_RATE, tune.CLIMB_RATE)
end

function A.resync(st, bodyH, tune)
    if type(bodyH) ~= "number" or bodyH ~= bodyH then return end
    st.flightBaseH = 0
    st.altitude = clamp((bodyH - (st.gearDatum or 0)) / tune.LIFT_HEIGHT_SCALE,
                        0, tune.MAX_ALTITUDE)
    st.flightTargetH = bodyH
    st.verticalSpeed = 0
end

function A.target(st, surfaceH, bodyH, dt, tune)
    local datum = st.gearDatum or 0
    local desired = (st.flightBaseH or 0) + datum + st.altitude * tune.LIFT_HEIGHT_SCALE
    if st.mode == "LANDING" then
        if st.altitude <= 0.01 then
            desired = surfaceH + datum - tune.LANDING_FINAL_SINK_M
        else
            desired = math.max(surfaceH + datum, desired)
        end
    end
    desired = math.min(desired, tune.HARD_MAX_BODY_H)
    local last = st.flightTargetH or bodyH or desired
    dt = math.max(0, math.min(dt, 1 / 15))
    st.flightTargetH = last + clamp(desired - last,
        -tune.TARGET_FALL_M_SEC * dt, tune.TARGET_RISE_M_SEC * dt)
    return st.flightTargetH
end

return A
