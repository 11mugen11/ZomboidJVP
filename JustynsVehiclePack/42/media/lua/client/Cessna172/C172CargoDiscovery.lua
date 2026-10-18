-- A mounted cargo vehicle can be the single vehicle returned for a square.
-- Discover the overlapping Cessna baggage independently; native container
-- access still decides door state, distance, installed trunk and permissions.
require "ISUI/ISInventoryPage"
local function discover(page,phase)
    if phase~="beforeFloor" or page.onCharacter then return end
    local player=getSpecificPlayer(page.player)
    local cell=getCell()
    if not player or not cell then return end
    local list=cell:getVehicles()
    if not list then return end
    local iterator=list:iterator()
    while iterator:hasNext() do
        local vehicle=iterator:next()
        if vehicle:getScript() and vehicle:getScript():getFullName()=="Base.Cessna172"
           and math.abs(vehicle:getZ()-player:getZ())<1 then
            local dx,dy=vehicle:getX()-player:getX(),vehicle:getY()-player:getY()
            if dx*dx+dy*dy<=64 then
                for i=0,vehicle:getPartCount()-1 do
                    local part=vehicle:getPartByIndex(i)
                    local container=part:getId()=="TruckBed" and part:getItemContainer()
                    if container and vehicle:canAccessContainer(i,player) then
                        local found=false
                        for _,button in ipairs(page.backpacks) do
                            if button.inventory==container then found=true;break end
                        end
                        if not found then
                            local title=getText("IGUI_VehiclePart"..container:getType())
                            local button=page:addContainerButton(container,nil,title,title)
                            page:checkExplored(button.inventory,player)
                        end
                    end
                end
            end
        end
    end
end
Events.OnRefreshInventoryWindowContainers.Add(discover)
