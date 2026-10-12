--[[
    AviationBookXP - makes reading an aviation manual actually TEACH the Aviation skill.

    ============================ WHY THIS FILE HAS TO EXIST ============================

    A Project Zomboid skill book does NOT grant XP. Read ISReadABook.checkMultiplier: all it
    ever calls is addXpMultiplier(). A Carpentry book makes the XP you earn from BUILDING
    count for more; the XP itself comes from the hammer, never from the page.

    Every vanilla skill has an activity behind it. Aviation's activity is flying - and flying
    is the thing the skill gates. So without this file the loop is closed against the player:
    no XP source, so no level 2, so no take-off, so no XP, for every player, forever. The
    books would be furniture and the aircraft would be permanently unflyable.

    This was found during the release audit, before publishing, by asking what actually
    produces the XP rather than assuming the book did.

    ============================ WHAT IT DOES ============================

    Finishing a manual brings the reader UP TO the highest level that manual teaches, and no
    further. Volume 1 teaches levels 1-2, so finishing it leaves you at exactly Aviation 2 -
    which is what the Cessna asks for. Volume 2 leaves you at 4, Volume 3 at 6.

    The level is DERIVED, never hardcoded:

        Aviation.setLevel(character, item:getMaxLevelTrained())

    so it works for any future manual any aircraft mod adds, with no numbers to keep in sync
    and no table to update. It is also naturally idempotent: re-reading a book you have
    already outgrown compares levels, finds nothing to teach and does nothing, so there is no
    read-it-twice exploit and no need to track what has been read.

    IT GOES THROUGH Aviation.setLevel RATHER THAN WRITING XP DIRECTLY. This file originally
    computed the shortfall to the book's ceiling and made one AddXPNoMultiplier call for it,
    which does not work: a single call deposits roughly a QUARTER of the amount requested
    (measured in syncPerkToLevel - 225 requested, 56.25 landed). The reader finished Volume 1
    and was still short of Aviation 2, so the book looked inert. setLevel is the path that
    tops the XP up in a bounded loop until it genuinely crosses the threshold.

    ============================ SCOPE ============================

    ISReadABook:perform is a vanilla global, so this wraps it - but the wrapper does one
    comparison and calls straight through for every book in the game that is not an aviation
    manual. A Carpentry book takes the original path having never entered this logic.

    It keys off the PERK, not off item names, so an aircraft mod that adds its own manual with
    `SkillTrained = Aviation` is handled here automatically without registering anything.
]]

require "Aviation/AviationFramework"

if AviationBookXP then return AviationBookXP end
AviationBookXP = {}

local installed = false

-- ONE-SHOT, NOT PER-BOOK. This runs for every book anyone reads, Carpentry included, so a
-- gate that fires before the aviation-manual identity check must never log on every read.
local warnedNoSkill = false

local function awardFor(character, item)
    if not (character and item and Aviation and Aviation.isSkillAvailable()) then
        if character and item and not warnedNoSkill then
            warnedNoSkill = true
            print("[Aviation] a book was read but the Aviation skill is not available - no " ..
                  "manual can teach anything until initSkill() succeeds. Logged once.")
        end
        return
    end
    local perk = Aviation.perk()
    if not perk then return end

    -- Only books that train THIS skill. SkillBook is keyed by the item script's
    -- `SkillTrained` string and AviationFramework registers the Aviation entry into it.
    local okSkill, skill = pcall(function() return item:getSkillTrained() end)
    if not okSkill or not skill then return end
    local entry = SkillBook and SkillBook[skill]
    if not entry or entry.perk ~= perk then return end

    -- FROM HERE ON THIS IS DEFINITELY AN AVIATION MANUAL, so every remaining exit logs. The
    -- reason is a real MP report: "books work in solo but not multiplayer", where the award
    -- simply never happened and there was nothing in the log to say which gate stopped it -
    -- an award and a silent no-op looked identical from outside. They do not any more.
    local okMax, maxLevel = pcall(function() return item:getMaxLevelTrained() end)
    if not okMax or type(maxLevel) ~= "number" or maxLevel < 1 then
        print(("[Aviation] manual read but its taught level is unreadable (ok=%s value=%s) - " ..
               "check LvlSkillTrained/NumLevelsTrained on the item script.")
              :format(tostring(okMax), tostring(maxLevel)))
        return
    end
    if maxLevel > 10 then maxLevel = 10 end

    -- WHY THIS GOES THROUGH Aviation.setLevel AND NOT A DIRECT XP WRITE.
    --
    -- The original version here computed the shortfall to the book's ceiling and made ONE
    -- AddXPNoMultiplier call for it. That does not work, and the framework already proved
    -- why: a single call deposits roughly a QUARTER of what is asked for. syncPerkToLevel's
    -- own instrumented run requested 225 - the exact cost of level 2 - and the perk ended up
    -- holding 56.25. So finishing Volume 1 credited about a quarter of the XP it needed and
    -- left the reader short of Aviation 2, which is the level the Cessna gates take-off on.
    -- The book appeared to do nothing, because the only visible effect - the level - never
    -- moved.
    --
    -- Aviation.setLevel is the path that was built to survive exactly this: it writes the
    -- stores, then tops the XP up in a bounded loop until the total genuinely crosses the
    -- threshold, then re-asserts the level. Reusing it means the book cannot drift away from
    -- the behaviour the rest of the framework was fixed to have.
    --
    -- COMPARE LEVELS, NOT XP. The old guard compared XP totals, which silently did the wrong
    -- thing for a reader whose level had been restored from the store but whose XP had been
    -- zeroed by a server sync: `award` came out positive and the book "taught" a level the
    -- reader already had. Comparing levels is what the rule actually means - a manual never
    -- demotes anyone, and re-reading one you have outgrown does nothing.
    local okCur, currentLevel = pcall(function() return character:getPerkLevel(perk) end)
    if not okCur or type(currentLevel) ~= "number" then currentLevel = 0 end
    if maxLevel <= currentLevel then
        -- NOT A FAULT, and the single most likely reason a manual "does nothing": you already
        -- have the level it teaches. Volume 1 teaches 2, so re-reading it at Aviation 2 is a
        -- no-op by design. Said out loud so it is never mistaken for a broken hook again.
        print(("[Aviation] manual teaches up to Aviation %d and you are already %d - nothing " ..
               "to learn from this volume."):format(maxLevel, currentLevel))
        -- AND SAY IT ON SCREEN, because in MULTIPLAYER nothing else will.
        --
        -- Vanilla already refuses an outgrown book, in ISReadABook:animEvent - but that whole
        -- branch is wrapped in `if isServer()`, and so is the doHaloText() call that explains
        -- it. On a server that has no UI the message goes nowhere, so the player sees the page
        -- count freeze and no reason why. In singleplayer isServer() is false, the branch never
        -- runs, and reading behaves completely differently - which is exactly why this reads as
        -- "books work in solo but not in MP" when both are in fact behaving as designed.
        --
        -- This runs client-side (perform() is a client path), so it puts the missing feedback
        -- back where the player can actually see it.
        pcall(function()
            if not isServer() then
                HaloTextHelper.addGoodText(character, getText("IGUI_PlayerText_KnowSkill"))
            end
        end)
        return
    end

    local before = 0
    pcall(function() before = character:getXp():getXP(perk) end)

    Aviation.setLevel(character, maxLevel)

    -- `or 0`: the print below is NOT inside a pcall, and :format("%d", nil) throws.
    local level = Aviation.getLevel(character) or 0
    local award = 0
    pcall(function() award = character:getXp():getXP(perk) - before end)

    -- THE VANILLA "READ" CHECKMARK AND THE PAGE COUNT.
    --
    -- ISInventoryPane:isLiteratureRead decides the tick, and it already handles skill books:
    --
    --     local skillBook = SkillBook[item:getSkillTrained()]
    --     if skillBook and (item:getMaxLevelTrained() < playerObj:getPerkLevel(skillBook.perk) + 1)
    --
    -- For Volume 1 that is `2 < level + 1`, i.e. it ticks at Aviation 2. So the missing
    -- checkmark was never a separate bug - it was the SAME bug as everything else here: the
    -- book never actually reached the level, so the test never passed. Landing the level
    -- lights the tick on its own, with nothing to add.
    --
    -- The second path it accepts is an exact page count, and that one IS worth closing.
    -- Vanilla's complete() sets the ITEM's pages to full but never mirrors that onto the
    -- CHARACTER's record; only update() does, from math.floor(pages * jobDelta) on each tick,
    -- so the stored count can finish a page short and read "219/220" forever. Writing the
    -- exact total here costs one call and makes the page display honest whatever the last
    -- tick happened to land on. complete() runs before perform(), so the item is already at
    -- its full count by the time this sees it.
    pcall(function()
        local pages = item:getNumberOfPages()
        if type(pages) == "number" and pages > 0 then
            item:setAlreadyReadPages(pages)
            character:setAlreadyReadPages(item:getFullType(), pages)
        end
    end)

    do
        -- MULTIPLAYER DURABILITY. The XP above is written client-side, which is how every
        -- vanilla skill is earned - but Aviation is a CUSTOM perk, and a level in a perk the
        -- server has not registered is overwritten on the next stat sync rather than saved.
        -- Recording the level the manual earned lets Aviation.restoreTrained put it back if
        -- that happens, so finishing a book means the same thing on a server as it does in
        -- singleplayer. Monotonic and earned-only: it can never grant an unearned level.
        pcall(function() Aviation.recordTrained(character, level) end)
        pcall(function()
            HaloTextHelper.addGoodText(character, ("Aviation %d"):format(level))
        end)
        print(("[Aviation] manual finished: +%.0f XP -> Aviation %d"):format(award, level))
    end
end

-- BOTH perform() AND complete() ARE WRAPPED, AND THE REASON IS MULTIPLAYER.
--
-- perform() alone is wrong. It was the original hook, it works perfectly in singleplayer, and
-- in multiplayer it never runs at all - proven from a live coop session where the hook logged
-- "installed" on both sides and then not one of awardFor's gates ever fired. The award simply
-- never happened.
--
-- Vanilla itself does every piece of skill-book work in complete(), not perform(): that is
-- where addXpMultiplier is called, where setAlreadyReadPages is written to its full count, and
-- where getAlreadyReadBook is updated. perform() only closes the book, plays a sound and pops
-- the action queue. Hooking perform() was hooking the janitor rather than the event.
--
-- complete() is also the RIGHT side in multiplayer. It runs on the SERVER there, which is the
-- authority for skills - a client-side level write gets reverted on the next stat sync, so an
-- award made server-side is the one that survives. In singleplayer complete() runs in the only
-- process there is, so the same hook covers both.
--
-- perform() is kept as well, because it is the client-side path and costs nothing: awardFor
-- compares LEVELS, so whichever of the two runs second finds nothing left to teach and returns.
-- `justAwarded` only stops that second, redundant pass from printing the "you already know
-- this" line and popping a halo text a moment after a successful read.
local justAwarded = nil

local function awardOnce(character, item)
    if character and item and justAwarded == item then return end
    local before = 0
    if character then pcall(function() before = Aviation.getLevel(character) end) end
    pcall(awardFor, character, item)
    local after = before
    if character then pcall(function() after = Aviation.getLevel(character) end) end
    if after > before then justAwarded = item end
end

function AviationBookXP.install()
    if installed then return true end
    if type(ISReadABook) ~= "table" or type(ISReadABook.perform) ~= "function"
       or type(ISReadABook.complete) ~= "function" then
        return false
    end
    installed = true

    local origComplete = ISReadABook.complete
    function ISReadABook:complete()
        local character, item = self.character, self.item
        -- The return value is vanilla's "this action finished" signal. Capture and pass it on
        -- unchanged: swallowing it would leave the timed action believing it never completed.
        local result = origComplete(self)
        -- forceStopped means the server refused the read (outgrown book, too advanced,
        -- illiterate). Nothing was learned, so nothing is awarded.
        if not self.forceStopped then awardOnce(character, item) end
        return result
    end

    local origPerform = ISReadABook.perform
    function ISReadABook:perform()
        -- Read the character and item BEFORE vanilla runs: perform() clears its own fields.
        local character, item = self.character, self.item
        origPerform(self)
        if not self.forceStopped then awardOnce(character, item) end
    end

    print("[Aviation] book XP hook installed on complete() and perform() (aviation manuals " ..
          "only; every other book takes the vanilla path).")
    return true
end

if not AviationBookXP.install() then
    if Events and Events.OnGameBoot then Events.OnGameBoot.Add(AviationBookXP.install) end
end
if Events and Events.OnGameStart then Events.OnGameStart.Add(AviationBookXP.install) end

return AviationBookXP
