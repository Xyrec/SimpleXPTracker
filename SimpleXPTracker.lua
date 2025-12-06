-- SimpleXPTracker.lua
-- Minimal XP/hour tracker for WoW Classic / Era (inspired by Runelite XP Tracker)
-- Place folder SimpleXPTracker in your AddOns directory.
-- If the addon doesn't load, update the ## Interface number in the .toc to match your client build.

-- Constants
local MAX_LEVEL = 60
local MAX_QUEST_XP_THRESHOLD = 5000  -- XP gains above this are likely quests, not mob kills
local MAX_RECENT_KILLS = 10  -- Number of recent kills to track for average
local UPDATE_INTERVAL = 0.5  -- Display update frequency in seconds

local addon = CreateFrame('Frame', 'SimpleXPTrackerFrame', UIParent)
addon:SetSize(312, 86)
addon:SetPoint('TOPLEFT', 200, -200)
addon:SetScale(1.5)
addon:SetMovable(true)
addon:EnableMouse(true)
addon:RegisterForDrag('LeftButton')
addon:SetScript('OnDragStart', function(self) self:StartMoving() end)
addon:SetScript('OnDragStop', function(self) self:StopMovingOrSizing() end)

-- Backdrop
addon.bg = addon:CreateTexture(nil, 'BACKGROUND')
addon.bg:SetAllPoints(addon)
addon.bg:SetColorTexture(0, 0, 0, 0.6)

-- Info line at top
addon.infoText = addon:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
addon.infoText:SetPoint('TOP', addon, 'TOP', 0, -12)
addon.infoText:SetText('Per hour: 0     Kills left: -     XP left: -')
addon.infoText:SetTextColor(1, 1, 1, 1)

-- Status (progress) bar (below info text)
addon.bar = CreateFrame('StatusBar', nil, addon)
addon.bar:SetPoint('TOPLEFT', 10, -32)
addon.bar:SetPoint('TOPRIGHT', -10, -32)
addon.bar:SetHeight(20)
addon.bar:SetMinMaxValues(0, 1)
addon.bar:SetValue(0)

-- Use ElvUI texture if available, otherwise use default
local barTexture = 'Interface\\TARGETINGFRAME\\UI-StatusBar'
if ElvUI then
    local E = unpack(ElvUI)
    if E and E.media and E.media.normTex then
        barTexture = E.media.normTex
    end
end
addon.bar:SetStatusBarTexture(barTexture)
addon.bar:GetStatusBarTexture():SetHorizTile(false)
addon.bar:GetStatusBarTexture():SetVertexColor(0, 0.6, 0, 1) -- Green color

addon.bar.bg = addon.bar:CreateTexture(nil, 'BACKGROUND')
addon.bar.bg:SetAllPoints(addon.bar)
addon.bar.bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

-- Level & percentage text (on the bar, left side)
addon.levelText = addon.bar:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
addon.levelText:SetPoint('LEFT', addon.bar, 'LEFT', 4, 0)
addon.levelText:SetText('Lv. 0  0.00%')
addon.levelText:SetTextColor(1, 0.82, 0, 1) -- Gold/yellow color

-- Timer text (on the bar, right side)
addon.timerText = addon.bar:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
addon.timerText:SetPoint('RIGHT', addon.bar, 'RIGHT', -4, 0)
addon.timerText:SetText('Stopped')
addon.timerText:SetTextColor(1, 0.82, 0, 1) -- Gold/yellow color

-- Time to level text (between the buttons)
addon.ttlText = addon:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
addon.ttlText:SetPoint('BOTTOM', addon, 'BOTTOM', 0, 10)
addon.ttlText:SetText('Time to level: --:--:--')
addon.ttlText:SetTextColor(1, 1, 1, 1)

-- Buttons at the bottom (using simple Button for ElvUI styling)
addon.startBtn = CreateFrame('Button', 'SimpleXPTrackerStartButton', addon)
addon.startBtn:SetSize(50, 20)
addon.startBtn:SetPoint('BOTTOMLEFT', 10, 6)
addon.startBtn:SetText('Start')
addon.startBtn:SetNormalFontObject('GameFontNormal')
addon.startBtn:SetHighlightFontObject('GameFontHighlight')

addon.resetBtn = CreateFrame('Button', 'SimpleXPTrackerResetButton', addon)
addon.resetBtn:SetSize(50, 20)
addon.resetBtn:SetPoint('BOTTOMRIGHT', -10, 6)
addon.resetBtn:SetText('Reset')
addon.resetBtn:SetNormalFontObject('GameFontNormal')
addon.resetBtn:SetHighlightFontObject('GameFontHighlight')

-- State
local running = false
local startTime = nil
local totalElapsed = 0 -- Total elapsed time across stop/start cycles
local sessionXP = 0
local lastXP = UnitXP('player') or 0
local lastMobXP = nil
local recentMobXP = {} -- Array to store last 10 mob XP gains
local totalKills = 0
local killsSinceReset = 0
local levelAtStart = UnitLevel('player') or 0

-- Helpers
local function IsMaxLevel()
    return UnitLevel('player') >= MAX_LEVEL
end

local function DisableAddon()
    addon:UnregisterAllEvents()
    addon:SetScript('OnUpdate', nil)
    addon:Hide()
end

local function formatTime(s)
    if not s or s<=0 then return '00:00:00' end
    local h = math.floor(s/3600)
    local m = math.floor((s%3600)/60)
    local sec = math.floor(s%60)
    return string.format('%02d:%02d:%02d', h, m, sec)
end

local function ParseMobXP(text)
    -- Parse combat log message to extract XP from mob kills
    -- Example: "Jade Ooze dies, you gain 538 experience. (+269 exp Rested bonus)"
    local xp = text:match("you gain (%d+) experience")
    if xp then
        xp = tonumber(xp)
        -- Only track if it looks like a mob kill (not a huge quest XP)
        if xp and xp > 0 and xp < MAX_QUEST_XP_THRESHOLD then
            return xp
        end
    end
    return nil
end

local function TrackMobKill(xp)
    lastMobXP = xp
    table.insert(recentMobXP, xp)
    -- Keep only the last MAX_RECENT_KILLS entries
    if #recentMobXP > MAX_RECENT_KILLS then
        table.remove(recentMobXP, 1)
    end
    totalKills = totalKills + 1
    killsSinceReset = killsSinceReset + 1
end

local function UpdateDisplay()
    local curXP = UnitXP('player') or 0
    local maxXP = UnitXPMax('player') or 1
    local level = UnitLevel('player') or 0
    local xpLeft = maxXP - curXP
    local pct = (curXP / maxXP) * 100
    
    -- Hide addon at max level
    if IsMaxLevel() then
        addon:Hide()
        return
    end
    
    -- Level and percentage on the bar (left side)
    addon.levelText:SetText(string.format('Lv. %d  %.2f%%', level, pct))

    -- progress bar value (0..1)
    addon.bar:SetMinMaxValues(0, maxXP)
    addon.bar:SetValue(curXP)

    -- Calculate total elapsed time
    local elapsed = totalElapsed
    if running and startTime then
        elapsed = elapsed + (GetTime() - startTime)
    end

    -- Timer on the bar (right side)
    addon.timerText:SetText(running and formatTime(elapsed) or 'Stopped')

    -- Use minimum 60 second baseline to prevent inflated rates
    local effectiveTime = math.max(60, elapsed)
    
    -- XP/hour and kills left info
    local xpPerHour = 0
    if effectiveTime > 0 then 
        xpPerHour = sessionXP / (effectiveTime / 3600) 
    end
    
    -- kills left based on weighted average of last 10 mob XP gains (Runelite method)
    local killsLeft = '-'
    if #recentMobXP > 0 then
        local totalXp = 0
        for _, xp in ipairs(recentMobXP) do
            totalXp = totalXp + xp
        end
        -- Weighted calculation: (xpLeft * numSamples) / totalXp
        killsLeft = math.ceil((xpLeft * #recentMobXP) / totalXp)
    end
    
    addon.infoText:SetText(string.format('XP/hr: %d     Kills left: %s     XP left: %d', 
        math.floor(xpPerHour+0.5), tostring(killsLeft), xpLeft))
    
    -- Time to level calculation (Runelite's integer-based formula)
    local ttl = '--:--:--'
    if sessionXP > 0 and xpLeft > 0 and elapsed > 0 then
        -- formula: (xpRemaining * secondsElapsed) / xpGained
        local secondsToLevel = (xpLeft * elapsed) / sessionXP
        ttl = formatTime(secondsToLevel)
    end
    addon.ttlText:SetText(string.format('Time to level: %s', ttl))
end

-- Button handlers
addon.startBtn:SetScript('OnClick', function()
    if not running then
        -- Starting/Resuming
        running = true
        startTime = GetTime()
        if sessionXP == 0 then
            -- First start: initialize everything
            levelAtStart = UnitLevel('player') or 0
            lastXP = UnitXP('player') or 0
            lastMobXP = nil
        end
        addon.startBtn:SetText('Stop')
    else
        -- Stopping (pause)
        running = false
        -- Add the current session time to total elapsed
        if startTime then
            totalElapsed = totalElapsed + (GetTime() - startTime)
        end
        startTime = nil
        addon.startBtn:SetText('Start')
    end
    UpdateDisplay()
end)

addon.resetBtn:SetScript('OnClick', function()
    sessionXP = 0
    totalElapsed = 0
    startTime = running and GetTime() or nil
    lastMobXP = nil
    recentMobXP = {} -- Clear the array
    totalKills = 0
    killsSinceReset = 0
    lastXP = UnitXP('player') or 0
    levelAtStart = UnitLevel('player') or 0
    UpdateDisplay()
end)

-- Event handling
addon:RegisterEvent('PLAYER_ENTERING_WORLD')
addon:RegisterEvent('PLAYER_XP_UPDATE')
addon:RegisterEvent('PLAYER_LEVEL_UP')
addon:RegisterEvent('CHAT_MSG_COMBAT_XP_GAIN')

addon:SetScript('OnEvent', function(self, event, ...)
    if event == 'PLAYER_ENTERING_WORLD' then
        lastXP = UnitXP('player') or 0
        -- Check if max level and disable addon completely
        if IsMaxLevel() then
            DisableAddon()
            return
        end
        UpdateDisplay()
        return
    elseif event == 'PLAYER_LEVEL_UP' then
        -- level up occurred: reset tracking for level progress
        lastXP = UnitXP('player') or 0
        -- Check if reached max level and disable addon completely
        if IsMaxLevel() then
            DisableAddon()
            return
        end
        UpdateDisplay()
        return
    elseif event == 'CHAT_MSG_COMBAT_XP_GAIN' then
        local text = ...
        local xp = ParseMobXP(text)
        if xp then
            TrackMobKill(xp)
        end
        return
    elseif event == 'PLAYER_XP_UPDATE' then
        local newXP = UnitXP('player') or 0
        local diff = newXP - lastXP
        -- if diff negative then probably leveled (XP wraps). handle via absolute value using maxXP of previous level is hard;
        -- so if negative, treat as level up and set diff = newXP (newXP after wrap)
        if diff < 0 then
            -- leveled: gained (lastMax - lastXP) + newXP ; but we don't have lastMax. Approximate by using newXP as gained this update.
            diff = newXP
        end
        if diff > 0 then
            -- Auto-start on first XP gain if never started
            if not running and sessionXP == 0 and totalElapsed == 0 then
                running = true
                startTime = GetTime()
                levelAtStart = UnitLevel('player') or 0
                addon.startBtn:SetText('Stop')
            end
            
            -- Only add to sessionXP if running
            if running then
                sessionXP = sessionXP + diff
            end
        end
        lastXP = newXP
        UpdateDisplay()
    end
end)

-- OnUpdate to refresh timer & display while running
addon:SetScript('OnUpdate', function(self, elapsed)
    if running then
        -- update display at UPDATE_INTERVAL (cheap)
        if not self._acc or self._acc > UPDATE_INTERVAL then
            self._acc = 0
            UpdateDisplay()
        else
            self._acc = (self._acc or 0) + elapsed
        end
    end
end)

-- slash command to toggle visibility
SLASH_SIMPLEXPTRACKER1 = '/sxp'
SlashCmdList['SIMPLEXPTRACKER'] = function(msg)
    if addon:IsShown() then addon:Hide() else addon:Show() end
end

-- initial update
UpdateDisplay()
