--[[
    AviationDistributions - puts the shared aviation manuals into the world's loot.

    PART OF THE FRAMEWORK, NOT OF ANY AIRCRAFT. Ships alongside AviationFramework.lua and is
    vendored the same way; the guard below means several aircraft mods carrying it is
    harmless.

    PURELY ADDITIVE. Every write appends to an EXISTING vanilla container's item list. Nothing
    is replaced, reordered, removed or re-weighted, so any other mod writing into the same
    containers is unaffected regardless of load order - and a container this file does not
    know about is simply skipped rather than created.

    RUNS ON OnPreDistributionMerge, which is the point at which ProceduralDistributions.list
    exists and before the engine builds its lookup tables. Running later would append to a
    table nothing reads again.

    WEIGHTS ARE LOW ON PURPOSE. These are 0.3 to 2.0 against neighbours in the tens, so a
    manual is a real find rather than shelf furniture - which is the same reasoning that
    makes the aircraft itself rare. The higher weights are where a pilot's books would
    actually be (an aircraft hangar, a technical bookshop shelf, a library reference section);
    the lower ones are the believable long shots.
]]

if AviationDistributions then return AviationDistributions end
AviationDistributions = {}

local V1, V2, V3 = "AviationManual1", "AviationManual2", "AviationManual3"

-- container name -> { {item, weight}, ... }
-- Volume 1 is the most findable everywhere; the later volumes cluster where real technical
-- material would be, so progression pulls the player toward aviation and technical locations.
local PLACEMENTS = {
    -- AVIATION GROUND CREW. The best odds in the game, and still uncommon. A hangar's own
    -- shelf is the one place a flight manual is not a coincidence.
    ArmyHangarMechanics     = { { V1, 2.0 }, { V2, 1.2 }, { V3, 0.8 } },
    ArmyHangarTools         = { { V1, 1.2 }, { V2, 0.7 }, { V3, 0.4 } },

    -- BOOKSHOPS, BY SECTION. A pilot's primer is shelved with transport and trades, not with
    -- general fiction - so the automotive and blue-collar sections carry it best, and the
    -- general shelf only sometimes. This is the difference between "books exist in bookshops"
    -- and a placement that looks like somebody thought about it.
    BookstoreAutomotive     = { { V1, 2.0 }, { V2, 1.2 }, { V3, 0.8 } },
    BookstoreBlueCollar     = { { V1, 1.4 }, { V2, 0.8 }, { V3, 0.5 } },
    BookstoreBooks          = { { V1, 0.9 }, { V2, 0.5 }, { V3, 0.3 } },
    BookstoreMisc           = { { V1, 0.6 }, { V2, 0.3 } },

    -- LIBRARIES. Reference and science shelves; the loanable copy.
    LibraryGeneralReference = { { V1, 1.2 }, { V2, 0.7 }, { V3, 0.4 } },
    LibraryScience          = { { V1, 0.9 }, { V2, 0.6 }, { V3, 0.4 } },
    LibraryBooks            = { { V1, 0.7 }, { V2, 0.4 }, { V3, 0.3 } },

    -- TECHNICAL AND MECHANICAL. A ground engineer's own shelf, and the places a working
    -- mechanic keeps manuals.
    GarageMechanics         = { { V1, 0.9 }, { V2, 0.5 } },
    MechanicShelfMisc       = { { V1, 0.7 }, { V2, 0.4 } },
    CrateMechanics          = { { V1, 0.6 }, { V2, 0.3 } },
    EngineerTools           = { { V1, 0.6 }, { V2, 0.3 } },

    -- EDUCATION AND OFFICES. The long shots that stop the placement feeling scripted - a
    -- ground-school textbook on a classroom shelf, somebody's ambition in a desk drawer.
    ClassroomShelves        = { { V1, 0.5 } },
    ClassroomDesk           = { { V1, 0.4 } },
    OfficeDesk              = { { V1, 0.3 } },
}

local done = false

local function insert()
    if done then return end
    if type(ProceduralDistributions) ~= "table" or type(ProceduralDistributions.list) ~= "table" then
        return
    end
    -- PLACEMENTS is keyed by name, so #PLACEMENTS is 0 - count while walking it.
    local added, skipped, containers = 0, 0, 0
    for container, entries in pairs(PLACEMENTS) do
        containers = containers + 1
        local dist = ProceduralDistributions.list[container]
        if dist and type(dist.items) == "table" then
            for _, e in ipairs(entries) do
                -- Never add the same item twice, however many times this runs or however many
                -- copies of the framework are installed.
                local present = false
                for i = 1, #dist.items, 2 do
                    if dist.items[i] == e[1] then present = true break end
                end
                if not present then
                    table.insert(dist.items, e[1])
                    table.insert(dist.items, e[2])
                    added = added + 1
                end
            end
        else
            skipped = skipped + 1
        end
    end
    done = true
    print(("[Aviation] manuals added to loot: %d entries into %d of %d containers (%d not " ..
           "present in this install, skipped)")
        :format(added, containers - skipped, containers, skipped))
end

AviationDistributions.insert = insert

if Events and Events.OnPreDistributionMerge then
    Events.OnPreDistributionMerge.Add(insert)
else
    insert()
end

return AviationDistributions
