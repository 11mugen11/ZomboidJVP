Events.OnServerStarted.Add(function()
    local ok, err = pcall(function()
        require "JVPActyFuel"
        require "Vehicles/TimedActions/ISRefuelFromGasPump"
        local v = BaseVehicle.new(getCell())
        v:setScript("Base.JVP_ActyFuelTruck")
        local tank = v:getPartById(JVPActyFuel.PART)
        assert(tank and tank:isContainer(), "Missing native bed container")
        assert(tank:getContainerCapacity() == 2000, "Native capacity is not 2000 L")
        JVPActyFuel.CreateTank(v, tank)
        assert(tank:getCondition() == 100, "New tank durability is not 100")
        assert(tank:getContainerContentAmount() == 0, "New tank not empty")
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
