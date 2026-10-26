Events.OnServerStarted.Add(function()
    local ok, err = pcall(function()
        require "JVPActyFuel"
        require "Vehicles/TimedActions/ISRefuelFromGasPump"
        for _, name in ipairs({ "Base.Amphora", "Base.AmphoraClosed" }) do
            local amphora = IsoThumpable.new(getCell())
            amphora:setSprite(name == "Base.AmphoraClosed" and "crafted_04_32" or "crafted_04_33")
            local script = ScriptManager.instance:getGameEntityScript(name)
            assert(script, "Missing amphora script " .. name)
            GameEntityFactory.CreateIsoObjectEntity(amphora, script, true)
            local fluid = amphora:getFluidContainer()
            assert(fluid, "Amphora has no native fluid component")
            print("[ACTY NATIVE TEST] amphora native capacity " .. tostring(fluid:getCapacity()))
            assert(fluid:getCapacity() == 300, "Amphora capacity mismatch")
            assert(fluid:canAddFluid(Fluid.Petrol), "Amphora rejects petrol: " .. name)
            fluid:addFluid(Fluid.Petrol, 10)
            assert(fluid:isPureFluid(Fluid.Petrol) and fluid:getAmount() == 10, "Amphora did not retain petrol")
            print("[ACTY NATIVE TEST] CONFIRMED " .. name .. " accepts and retains petrol; capacity 300 L")
            assert(JVPActyFuel.amphoraFluid(amphora) == fluid, "Native amphora identity gate failed")
            local moved = JVPActyFuel.fillAmphora(amphora, 500, 500)
            assert(moved == 290 and fluid:getAmount() == 300, "Native truck-to-amphora helper did not clamp at 300 L")
            assert(JVPActyFuel.fillAmphora(amphora, 50, 50) == 0, "Full amphora still accepted fuel")
            fluid:Empty()
            fluid:addFluid(Fluid.Water, 10)
            assert(not JVPActyFuel.canFillAmphora(amphora), "Water amphora allowed petrol mixing")
            assert(JVPActyFuel.fillAmphora(amphora, 100, 100) == 0 and fluid:getAmount() == 10, "Water amphora was modified")
            print("[ACTY NATIVE TEST] PASS native amphora pumping helper, 300 L capacity clamp, full tank and contamination rejection")
        end
        local v = BaseVehicle.new(getCell())
        v:setScript("Base.JVP_ActyFuelTruck")
        local tank = v:getPartById(JVPActyFuel.PART)
        assert(tank and tank:isContainer(), "Missing native bed container")
        assert(tank:getContainerCapacity() == 2000, "Native capacity is not 2000 L")
        JVPActyFuel.CreateTank(v, tank)
        assert(tank:getCondition() == 100, "New tank durability is not 100")
        assert(tank:getContainerContentAmount() == 0, "New tank not empty")
        -- Run the production server tick against the actual Java vehicle part.
        -- Position/operator doubles avoid requiring connected graphical clients.
        require "JVPActyFuelServer"
        local F = JVPActyFuel
        local pt = {getX=function() return 0 end,getY=function() return 0 end}
        local host = {
            getScriptName=function() return F.SCRIPT end,
            getPartById=function() return tank end,
            getSquare=function() return {} end,
            getCurrentSpeedKmHour=function() return 0 end,
            getAreaCenter=function() return pt end,getZ=function() return 0 end,
            transmitPartModData=function() v:transmitPartModData(tank) end,
        }
        local operator = {isDead=function() return false end,getVehicle=function() return nil end,
            getX=function() return 0 end,getY=function() return 0 end,getZ=function() return 0 end}
        local station = {units=100,data={},getModData=function(s) return s.data end,
            getPipedFuelAmount=function(s) return s.units end,
            setPipedFuelAmount=function(s,n) assert(n==math.floor(n));s.units=n end,
            getObjectIndex=function() return 0 end,getX=function() return 0 end,
            getY=function() return 0 end,getZ=function() return 0 end,
            getSquare=function() return {hasGridPower=function() return true end} end,
            transmitModData=function() end}
        local now = getTimestampMs()
        F.sessions[999] = {player=operator,truck=host,mode="load",pump=station,last=now-500,alive=now}
        F.tick()
        F.sessions = {}
        assert(tank:getContainerContentAmount()==4, "Server tick did not retain fuel in native bed")
        assert(tank:getModData().contentAmount==4, "Native saved fuel mismatch")
        assert(math.abs(F.pumpLitres(station)-121)<0.001, "Station conservation failed")
        print("[ACTY NATIVE TEST] PASS production server fill tick retains and persists fuel in actual Java vehicle part")
        tank:setContainerContentAmount(0)
        local pump = { units = 100 }
        function pump:getPipedFuelAmount() return self.units end
        function pump:setPipedFuelAmount(value) self.units = math.floor(value) end
        local action = ISRefuelFromGasPump:new({}, tank, pump)
        assert(action.maxTime > 0, "Station action is infinite")
        assert(action.tankTarget == 125, "Incorrect game station conversion")
        action.getJobDelta = function() return 1 end
        action.character = { setMetabolicTarget = function() end }
        action:update()
        assert(pump.units == 0, "Game station units were not debited")
        assert(action:complete(), "Native station action did not complete")
        assert(tank:getContainerContentAmount() == 125, "Native bed tank did not fill")
        assert(tank:getModData().contentAmount == 125, "Bed fuel not persisted in native mod data")
        assert(JVPActyFuel.tankLabel(tank) == "Gas Tank EXTERNAL - 6% - 100%", "Incorrect mechanics label")
        tank:setContainerContentAmount(1990)
        pump.units = 100
        action = ISRefuelFromGasPump:new({}, tank, pump)
        assert(action.tankTarget == 2000 and action.maxTime == 500, "Native full-tank duration/capacity incorrect")
        assert(action:complete() and tank:getContainerContentAmount() == 2000, "Native full tank failed")
        tank:setCondition(73)
        assert(JVPActyFuel.tankLabel(tank) == "Gas Tank EXTERNAL - 100% - 73%", "Live durability label failed")
        assert(tank:getContainerCapacity() == 2000, "Durability changed fixed bed capacity")
        print("[ACTY NATIVE TEST] PASS actual B42 vehicle script, native 2000 L part, finite vanilla pump action, fuel writes, mod-data persistence and fuel/durability label")
    end)
    if not ok then print("[ACTY NATIVE TEST] FAIL " .. tostring(err)) end
    print("[ACTY NATIVE TEST] DONE")
end)
