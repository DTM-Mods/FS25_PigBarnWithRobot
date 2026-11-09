-- Pig feed hoppers and feeding for the pig barn.
--
-- The four robot hoppers each take one pig food group, with every crop the map counts in that group:
--   silo outside  = base feed  (corn, sorghum, ...)
--   bin 3         = grains     (wheat, barley, ...)
--   bin 1         = protein    (soybeans, canola, sunflowers, ...)
--   bin 2         = root crops (potatoes, sugar beet, ...)
-- The groups and their shares come from the map's PIGFOOD mixture (base 50 %, grains 25 %, protein 20 %,
-- root crops 5 % on the base maps).
--
-- The hoppers store into this specialization, not into the robot. Every in-game hour the barn is fed from them:
-- each group delivers its share of 1.5x what the pigs eat per hour (like the base feeding robot), as far as it has
-- stock, and the robot drives its round. A group that runs empty only stops its own share.
--
-- Only checked FS25 functions are used: the unload trigger target contract (UnloadTrigger.lua), the husbandry
-- food functions (addFood, getFreeFoodCapacity, getFoodLitersPerHour) and the placeable save / stream events.

PlaceablePigFeedRobot = {}

PlaceablePigFeedRobot.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".pigFeedRobot"

local LOG_PREFIX = "PigBarnWithRobot: "

-- One entry per hopper: the crop that marks its pig food group, its trigger node names in the robot i3d, its
-- capacity, its unloading spot in pigFeedRobot.xml (whose fill volume shows the hopper level), the bin's fill
-- volume node in the robot i3d (the silo has none) and its name in warnings
PlaceablePigFeedRobot.HOPPERS = {
    {marker="MAIZE",   nodePrefix="exactFillRootNodeMineralFeed", capacity=1000000, spotIndex=4, volumeNode=nil,                label="base feed silo"},
    {marker="WHEAT",   nodePrefix="exactFillRootNodeHay",         capacity=500000,  spotIndex=3, volumeNode="fillVolumeHay",    label="grain bin"},
    {marker="SOYBEAN", nodePrefix="exactFillRootNodeSilage",      capacity=400000,  spotIndex=1, volumeNode="fillVolumeSilage", label="protein bin"},
    {marker="POTATO",  nodePrefix="exactFillRootNodeStraw",       capacity=120000,  spotIndex=2, volumeNode="fillVolumeStraw",  label="root crop bin"},
}

-- Warn the owner when a hopper or the straw has less than this many in-game months left at the pigs' current rate
PlaceablePigFeedRobot.LOW_SUPPLY_MONTHS = 1

-- The barn is fed 1.5x what the pigs eat per hour, like the base game feeding robot
PlaceablePigFeedRobot.FEED_FACTOR = 1.5

local function getRobot(placeable)
    local robotSpec = placeable.spec_husbandryFeedingRobot
    return robotSpec ~= nil and robotSpec.feedingRobot or nil
end

function PlaceablePigFeedRobot.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableHusbandryFeedingRobot, specializations)
end

function PlaceablePigFeedRobot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onReadUpdateStream", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteUpdateStream", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onHourChanged", PlaceablePigFeedRobot)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceablePigFeedRobot)
end

function PlaceablePigFeedRobot.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateFeeding", PlaceablePigFeedRobot.updateFeeding)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateInfo", PlaceablePigFeedRobot.updateInfo)
end

-- Pig food group title (e.g. "Grain"), or the crop names when the animal food data has none
local function getGroupTitle(foodSystem, fillTypes)
    local animalSystem = g_currentMission.animalSystem
    local animalTypeIndex = animalSystem ~= nil and animalSystem:getTypeIndexByName("PIG") or nil
    local animalFood = animalTypeIndex ~= nil and foodSystem:getAnimalFood(animalTypeIndex) or nil
    if animalFood ~= nil and animalFood.groups ~= nil then
        for _, group in pairs(animalFood.groups) do
            for _, fillTypeIndex in pairs(group.fillTypes) do
                if fillTypeIndex == fillTypes[1] and group.title ~= nil then
                    return group.title
                end
            end
        end
    end

    local titles = {}
    for _, fillTypeIndex in ipairs(fillTypes) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        table.insert(titles, fillType ~= nil and fillType.title or "?")
    end
    return table.concat(titles, ", ")
end

-- The hopper groups from the map's PIGFOOD mixture, in HOPPERS order
function PlaceablePigFeedRobot.createGroups()
    local groups = {}
    local foodSystem = g_currentMission.animalFoodSystem
    local pigFoodIndex = g_fillTypeManager:getFillTypeIndexByName("PIGFOOD")
    local mixture = foodSystem ~= nil and pigFoodIndex ~= nil and foodSystem:getMixtureByFillType(pigFoodIndex) or nil
    if mixture == nil or mixture.ingredients == nil then
        Logging.warning(LOG_PREFIX .. "the map has no PIGFOOD mixture, the hoppers can't take anything")
        return groups
    end

    local totalWeight = 0
    for _, ingredient in ipairs(mixture.ingredients) do
        totalWeight = totalWeight + ingredient.weight
    end

    for _, hopper in ipairs(PlaceablePigFeedRobot.HOPPERS) do
        local markerIndex = g_fillTypeManager:getFillTypeIndexByName(hopper.marker)
        local found = nil
        for _, ingredient in ipairs(mixture.ingredients) do
            for _, fillTypeIndex in ipairs(ingredient.fillTypes) do
                if fillTypeIndex == markerIndex then
                    found = ingredient
                end
            end
        end

        if found == nil then
            Logging.warning(LOG_PREFIX .. "no pig food group contains %s, its hopper stays empty", hopper.marker)
        else
            local group = {
                hopper = hopper,
                fillTypes = found.fillTypes,
                fillTypeSet = {},
                foodFillType = found.fillTypes[1],
                weight = totalWeight > 0 and found.weight / totalWeight or 0,
                capacity = hopper.capacity,
                fillLevel = 0,
                lastFillType = nil, -- crop last tipped, shown in the bin
                warnState = 0,
                title = getGroupTitle(foodSystem, found.fillTypes)
            }
            for _, fillTypeIndex in ipairs(found.fillTypes) do
                group.fillTypeSet[fillTypeIndex] = true
            end
            group.info = {title=group.title, text=""}
            table.insert(groups, group)
        end
    end

    return groups
end

function PlaceablePigFeedRobot:onLoad(savegame)
    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    spec.groups = PlaceablePigFeedRobot.createGroups()
    spec.dirtyFlag = self:getNextDirtyFlag()
    spec.robotStockMoved = false
    spec.lastHourKey = nil
    spec.robotStartPending = false
    spec.robotRetryTimer = 0
    spec.binsSynced = false
    spec.load = {}
    spec.loadTotal = 0
    spec.loadAtStart = 0
    spec.loadAge = 0
    spec.straw = {warnState = 0}
    spec.infoStraw = {title="Straw lasts", text=""}
    spec.infoFoodUse = {title="Pigs eat", text=""}
    spec.infoProductivity = {title="Productivity", text=""}
end

function PlaceablePigFeedRobot:onDelete()
    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    if spec ~= nil and spec.watchdog ~= nil then
        g_currentMission:removeUpdateable(spec.watchdog)
        spec.watchdog = nil
    end
end

local function getHourKey()
    local environment = g_currentMission.environment
    return (environment.currentMonotonicDay or 0) * 24 + (environment.currentHour or 0)
end

-- Hour watchdog (server): the barn's hourly cycle (feeding, production, slurry, hoppers) comes from the game's
-- HOUR_CHANGED message. If another mod errors while handling that message, the game stops delivering it to every
-- later subscriber, including this barn. When the clock reaches a new hour and the barn's hourly update hasn't
-- arrived a couple of frames later, the watchdog runs the barn's own hourly update.
function PlaceablePigFeedRobot.createHourWatchdog(placeable, spec)
    local watchdog = {}

    function watchdog.update(_, dt)
        if not spec.binsSynced then
            spec.binsSynced = true
            PlaceablePigFeedRobot.updateBinVisuals(placeable, spec)
        end

        PlaceablePigFeedRobot.updateLoad(placeable, spec, dt)

        if spec.robotStartPending then
            spec.robotRetryTimer = spec.robotRetryTimer - dt
            if spec.robotRetryTimer <= 0 then
                spec.robotRetryTimer = 500
                PlaceablePigFeedRobot.tryStartRobot(placeable, spec)
            end
        end

        local hourKey = getHourKey()
        if hourKey == spec.lastHourKey then
            spec.pendingHourKey = nil
            return
        end

        if spec.pendingHourKey ~= hourKey then
            spec.pendingHourKey = hourKey
            spec.pendingFrames = 0
            return
        end

        spec.pendingFrames = spec.pendingFrames + 1
        if spec.pendingFrames < 2 then
            return
        end

        Logging.warning(LOG_PREFIX .. "the hourly update for hour %d did not arrive (another mod failed while handling it), running it for this barn",
            g_currentMission.environment.currentHour or -1)
        spec.lastHourKey = hourKey
        spec.pendingHourKey = nil
        placeable:hourChanged(g_currentMission.environment.currentHour)
    end

    return watchdog
end

-- Unload trigger target for one hopper: takes every crop of the group into the group's storage
local function createHopperTarget(placeable, spec, group)
    local target = {}

    function target.getIsFillTypeAllowed(_, fillTypeIndex)
        return group.fillTypeSet[fillTypeIndex] == true
    end

    function target.getIsToolTypeAllowed(_, toolType)
        return true
    end

    function target.getFreeCapacity(_, fillTypeIndex)
        if not group.fillTypeSet[fillTypeIndex] then
            return 0
        end
        return math.max(group.capacity - group.fillLevel, 0)
    end

    function target.addFillLevelFromTool(_, farmId, deltaFillLevel, fillTypeIndex, fillPositionData, toolType, extraAttributes)
        if not group.fillTypeSet[fillTypeIndex] or deltaFillLevel <= 0 then
            return 0
        end

        local applied = math.min(deltaFillLevel, group.capacity - group.fillLevel)
        if applied <= 0 then
            return 0
        end

        group.fillLevel = group.fillLevel + applied
        group.lastFillType = fillTypeIndex
        if placeable.isServer then
            placeable:raiseDirtyFlags(spec.dirtyFlag)
        end
        PlaceablePigFeedRobot.updateBinVisuals(placeable, spec, group)
        return applied
    end

    return target
end

-- Points the robot's hopper unload triggers at the hopper groups
function PlaceablePigFeedRobot:onFinalizePlacement()
    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    local robotSpec = self.spec_husbandryFeedingRobot
    local robot = robotSpec ~= nil and robotSpec.feedingRobot or nil
    if robot == nil or spec.hoppersConnected then
        return
    end
    spec.hoppersConnected = true

    -- the robot's own ingredient list is empty now, the hopper lines come from updateInfo below
    if robot.infos ~= nil then
        robot.infos = {}
    end

    local groupByPrefix = {}
    for _, group in ipairs(spec.groups) do
        group.target = createHopperTarget(self, spec, group)
        groupByPrefix[group.hopper.nodePrefix] = group
    end

    local numTriggers = 0
    local function visit(node)
        local object = g_currentMission:getNodeObject(node)
        if object ~= nil and object.target == robot and object.setTarget ~= nil and object.exactFillRootNode ~= nil then
            local name = getName(object.exactFillRootNode)
            for prefix, group in pairs(groupByPrefix) do
                if string.sub(name, 1, #prefix) == prefix then
                    object.fillTypes = {}
                    for fillTypeIndex in pairs(group.fillTypeSet) do
                        object.fillTypes[fillTypeIndex] = true
                    end
                    object.fillTypeConversions = {}
                    object:setTarget(group.target)
                    numTriggers = numTriggers + 1
                    break
                end
            end
        end

        for i = 0, getNumOfChildren(node) - 1 do
            visit(getChildAt(node, i))
        end
    end
    visit(self.rootNode)

    -- the silo has one trigger, each bin two
    if numTriggers < 2 * #spec.groups - 1 then
        Logging.warning(LOG_PREFIX .. "only %d hopper triggers found for %d pig food groups", numTriggers, #spec.groups)
    end

    if self.isServer then
        spec.lastHourKey = getHourKey()
        spec.watchdog = PlaceablePigFeedRobot.createHourWatchdog(self, spec)
        g_currentMission:addUpdateable(spec.watchdog)
    else
        PlaceablePigFeedRobot.updateBinVisuals(self, spec)
    end
end

local function findNodeByName(node, name)
    if getName(node) == name then
        return node
    end
    for i = 0, getNumOfChildren(node) - 1 do
        local found = findNodeByName(getChildAt(node, i), name)
        if found ~= nil then
            return found
        end
    end
    return nil
end

-- Bin visuals: the robot's unloading spots draw their fill volume from their own fill level. The hoppers store
-- here, so their levels are copied into the spots, only for the look (updateFeeding keeps the robot from using them).
function PlaceablePigFeedRobot.updateBinVisuals(placeable, spec, onlyGroup)
    local robot = getRobot(placeable)
    if robot == nil or robot.unloadingSpots == nil then
        return
    end

    -- an older version may still have crops in the robot itself: move them before the spots get overwritten
    if placeable.isServer and not spec.robotStockMoved then
        PlaceablePigFeedRobot.moveRobotStock(placeable, spec)
    end

    local function robotUpdateSpot(spot)
        if robot.updateUnloadingSpot ~= nil then
            local ok, err = pcall(robot.updateUnloadingSpot, robot, spot)
            if not ok and not spec.binVisualErrorLogged then
                spec.binVisualErrorLogged = true
                Logging.warning(LOG_PREFIX .. "bin fill display failed: %s", tostring(err))
            end
        end
    end

    for _, group in ipairs(spec.groups) do
        if onlyGroup == nil or onlyGroup == group then
            local spot = robot.unloadingSpots[group.hopper.spotIndex]
            local level = math.floor(math.max(math.min(group.fillLevel, spot ~= nil and spot.capacity or group.capacity), 0))
            local levelChanged = false
            if spot ~= nil and spot.fillLevel ~= nil and spot.fillLevel ~= level then
                levelChanged = true
                spot.fillLevel = level
                robotUpdateSpot(spot)
            end

            if placeable.isClient and group.hopper.volumeNode ~= nil then
                local volume = PlaceablePigFeedRobot.getBinVolume(placeable, spec, group)
                if volume ~= nil then
                    -- does the robot draw the copied level? If its fill volume stays hidden with crops in the bin,
                    -- the barn draws the pile itself from now on
                    if group.binMode == nil and level > 0 then
                        if spot ~= nil and spot.fillLevel ~= nil then
                            robotUpdateSpot(spot)
                        end
                        local ok, visible = pcall(getVisibility, volume)
                        group.binMode = (ok and visible) and "robot" or "manual"
                    end

                    if group.binMode == "manual" then
                        PlaceablePigFeedRobot.drawBin(group, volume, level)
                    end
                end

                if levelChanged or group.shownFillType ~= group.lastFillType then
                    PlaceablePigFeedRobot.applyBinFillType(placeable, spec, group, spot)
                end
            end
        end
    end
end

-- The fill plane shape the robot made for the bin (created under the bin's fill volume node), nil if there is none
local function getBinBaseNode(placeable, group)
    if group.volumeBaseNode == nil then
        group.volumeBaseNode = findNodeByName(placeable.rootNode, group.hopper.volumeNode)
    end
    return group.volumeBaseNode
end

function PlaceablePigFeedRobot.getBinVolume(placeable, spec, group)
    if group.volumeShape == nil then
        local baseNode = getBinBaseNode(placeable, group)
        if baseNode ~= nil and getNumOfChildren(baseNode) > 0 then
            group.volumeShape = getChildAt(baseNode, 0)
        else
            -- not made (yet): look again next time
            if not spec.binVolumeMissingLogged then
                spec.binVolumeMissingLogged = true
                Logging.warning(LOG_PREFIX .. "no fill volume found in the %s, the bins can't show their crops", group.hopper.label)
            end
        end
    end
    return group.volumeShape
end

-- Size of the square the barn spreads crops over in a bin (meters); the bin's walls shape the pile
PlaceablePigFeedRobot.BIN_SPREAD = 3

-- Draws the hopper level into the bin's fill plane (the engine's fillPlaneAdd works in liters, like vehicle trailers)
function PlaceablePigFeedRobot.drawBin(group, volume, level)
    local delta = level - (group.drawnLevel or 0)
    if math.abs(delta) >= 1 then
        local size = PlaceablePigFeedRobot.BIN_SPREAD
        local x, y, z = localToWorld(volume, -size * 0.5, 0, -size * 0.5)
        local d1x, d1y, d1z = localDirectionToWorld(volume, size, 0, 0)
        local d2x, d2y, d2z = localDirectionToWorld(volume, 0, 0, size)
        local ok = pcall(fillPlaneAdd, volume, delta, x, y, z, d1x, d1y, d1z, d2x, d2y, d2z)
        if ok then
            group.drawnLevel = level
        end
    end
    pcall(setVisibility, volume, level > 0)
end

-- Bin look: the bin's fill volume shows the crop last tipped (the robot draws it with its spot's fixed crop).
-- FS25 fill volumes take their crop texture from the "fillTypeId" shader parameter of the fill plane shape, which
-- the engine creates under the bin's fill volume node.
function PlaceablePigFeedRobot.applyBinFillType(placeable, spec, group, spot)
    if group.lastFillType == nil or group.hopper.volumeNode == nil then
        return
    end

    local textureArrayIndex = g_fillTypeManager:getTextureArrayIndexByFillTypeIndex(group.lastFillType)
    if textureArrayIndex == nil then
        return
    end

    local shapes = {}
    if spot ~= nil and type(spot.fillVolume) == "table" and type(spot.fillVolume.volume) == "number" then
        table.insert(shapes, spot.fillVolume.volume)
    end

    local function addChildren(node)
        for i = 0, getNumOfChildren(node) - 1 do
            local child = getChildAt(node, i)
            table.insert(shapes, child)
            addChildren(child)
        end
    end
    local baseNode = getBinBaseNode(placeable, group)
    if baseNode ~= nil then
        addChildren(baseNode)
    end

    for _, shape in ipairs(shapes) do
        pcall(setShaderParameter, shape, "fillTypeId", textureArrayIndex - 1, 0, 0, 0, false)
    end
    if #shapes > 0 then
        group.shownFillType = group.lastFillType
    end
end

-- Runs func with the robot's spots empty, so the base robot can't mix feed from the copied hopper levels
local function withEmptyRobotSpots(placeable, func, ...)
    local robot = getRobot(placeable)
    local saved = {}
    if robot ~= nil and robot.unloadingSpots ~= nil then
        for i, spot in pairs(robot.unloadingSpots) do
            saved[i] = spot.fillLevel
            spot.fillLevel = 0
        end
    end

    local results = {pcall(func, ...)}

    if robot ~= nil and robot.unloadingSpots ~= nil then
        for i, spot in pairs(robot.unloadingSpots) do
            if saved[i] ~= nil then
                spot.fillLevel = saved[i]
            end
        end
    end

    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2)
end

-- Moves crops a barn built with an older version stored in the robot itself into the hoppers (once, server only)
function PlaceablePigFeedRobot.moveRobotStock(placeable, spec)
    if spec.robotStockMoved then
        return
    end
    spec.robotStockMoved = true

    local robot = placeable.spec_husbandryFeedingRobot ~= nil and placeable.spec_husbandryFeedingRobot.feedingRobot or nil
    if robot == nil or robot.getFillLevel == nil or robot.removeFillLevel == nil then
        return
    end

    for _, group in ipairs(spec.groups) do
        for _, fillTypeIndex in ipairs(group.fillTypes) do
            local ok, fillLevel = pcall(robot.getFillLevel, robot, fillTypeIndex)
            if ok and type(fillLevel) == "number" and fillLevel > 0 then
                local amount = math.min(fillLevel, group.capacity - group.fillLevel)
                local removedOk, removed = pcall(robot.removeFillLevel, robot, amount, fillTypeIndex)
                if removedOk and type(removed) == "number" and removed > 0 then
                    group.fillLevel = group.fillLevel + removed
                    placeable:raiseDirtyFlags(spec.dirtyFlag)
                end
            end
        end
    end
end

-- Feeds the barn from the hoppers once per in-game hour (server)
function PlaceablePigFeedRobot.feedFromHoppers(placeable)
    local spec = placeable[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    if #spec.groups == 0 then
        return
    end

    PlaceablePigFeedRobot.moveRobotStock(placeable, spec)

    -- whatever the robot still carries from the last hour goes into the barn first, unless it is still on its
    -- round (fast forward): then the new feed joins the load it is dropping
    local robot = getRobot(placeable)
    local robotState = robot ~= nil and robot.state or {}
    local robotBusy = robot ~= nil and robot.stateIndex ~= nil and robotState.PAUSED ~= nil
        and robot.stateIndex ~= robotState.PAUSED and robot.stateIndex ~= robotState.LOADING
    if not robotBusy then
        PlaceablePigFeedRobot.flushLoad(placeable, spec, nil)
    end

    local timeAdjustment = g_currentMission.environment.timeAdjustment or 1
    local need = placeable:getFoodLitersPerHour() * timeAdjustment * PlaceablePigFeedRobot.FEED_FACTOR
    if need <= 0 then
        PlaceablePigFeedRobot.checkSupplies(placeable, spec)
        return
    end

    local amounts = {}
    local total = 0
    for i, group in ipairs(spec.groups) do
        amounts[i] = math.min(need * group.weight, group.fillLevel)
        total = total + amounts[i]
    end

    local freeCapacity = placeable:getFreeFoodCapacity(spec.groups[1].foodFillType)
    if total > freeCapacity and total > 0 then
        local scale = freeCapacity / total
        for i in ipairs(amounts) do
            amounts[i] = amounts[i] * scale
        end
    end

    -- the robot takes the hour's feed from the hoppers and drops it along the feed alley on its round
    local loaded = 0
    for i, group in ipairs(spec.groups) do
        if amounts[i] > 0 then
            group.fillLevel = math.max(group.fillLevel - amounts[i], 0)
            spec.load[i] = (spec.load[i] or 0) + amounts[i]
            loaded = loaded + amounts[i]
        end
    end

    if loaded > 0 then
        placeable:raiseDirtyFlags(spec.dirtyFlag)
        local merging = robotBusy and spec.loadTotal > 0
        spec.loadTotal = spec.loadTotal + loaded

        if merging then
            spec.loadAtStart = spec.loadAtStart + loaded
        else
            spec.loadAtStart = spec.loadTotal
            spec.loadAge = 0
            spec.robotSeenFeeding = false
            spec.robotLeftPause = robotBusy
        end

        -- without a feeding spline to follow the barn gets the feed right away
        if robot == nil or robot.getFeedingFactor == nil then
            PlaceablePigFeedRobot.flushLoad(placeable, spec, nil)
        end

        spec.robotStartPending = true
        spec.robotRetryTimer = 0
            PlaceablePigFeedRobot.tryStartRobot(placeable, spec)
    end
    PlaceablePigFeedRobot.updateBinVisuals(placeable, spec)
    PlaceablePigFeedRobot.checkSupplies(placeable, spec)
end

-- 1234567 -> "1,234,567"
local function formatLiters(liters)
    local text = tostring(math.floor(math.max(liters, 0) + 0.5))
    local formatted
    repeat
        text, formatted = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
    until formatted == 0
    return text
end

-- In-game hours one month lasts
local function getHoursPerMonth()
    return 24 * (g_currentMission.environment.daysPerPeriod or 1)
end

-- Liters per in-game hour the pigs eat from one group (1.0x, what the barn uses up in the long run)
local function getGroupUsePerHour(placeable, group)
    local timeAdjustment = g_currentMission.environment.timeAdjustment or 1
    local ok, litersPerHour = pcall(placeable.getFoodLitersPerHour, placeable)
    if not ok or type(litersPerHour) ~= "number" then
        return 0
    end
    return litersPerHour * timeAdjustment * group.weight
end

local function getStrawUsePerHour(placeable)
    local strawSpec = placeable.spec_husbandryStraw
    if strawSpec == nil or strawSpec.inputLitersPerHour == nil then
        return 0
    end
    return strawSpec.inputLitersPerHour * (g_currentMission.environment.timeAdjustment or 1)
end

local function getStrawLevel(placeable)
    if placeable.getHusbandryFillLevel == nil or FillType == nil or FillType.STRAW == nil then
        return nil
    end
    local ok, level = pcall(placeable.getHusbandryFillLevel, placeable, FillType.STRAW)
    return ok and type(level) == "number" and level or nil
end

-- "4.2 months", "3 days", "5 h" or "-" when nothing is used
function PlaceablePigFeedRobot.formatTimeLeft(level, usePerHour)
    if usePerHour <= 0 then
        return "-"
    end
    local hours = level / usePerHour
    local hoursPerMonth = getHoursPerMonth()
    if hours >= hoursPerMonth then
        return string.format("%.1f months", hours / hoursPerMonth)
    elseif hours >= 24 then
        return string.format("%d days", math.floor(hours / 24))
    end
    return string.format("%d h", math.floor(hours))
end

-- 0 = enough, 1 = low (less than LOW_SUPPLY_MONTHS left), 2 = empty
local function getSupplyState(level, usePerHour)
    if usePerHour <= 0 then
        return 0
    elseif level < 1 then
        return 2
    elseif level / usePerHour < PlaceablePigFeedRobot.LOW_SUPPLY_MONTHS * getHoursPerMonth() then
        return 1
    end
    return 0
end

-- Low supply warnings for the barn's owner (on every machine that shows them, after the levels changed).
-- Each hopper and the straw warn once when they get low and once when they run empty.
function PlaceablePigFeedRobot.checkSupplies(placeable, spec)
    if not placeable.isClient or g_currentMission:getFarmId() ~= placeable:getOwnerFarmId() then
        return
    end

    local function check(holder, label, level, usePerHour)
        local state = getSupplyState(level, usePerHour)
        if state > (holder.warnState or 0) then
            local text
            if state == 2 then
                text = string.format("Pig barn: the %s is empty", label)
            else
                text = string.format("Pig barn: the %s is low, %s left", label, PlaceablePigFeedRobot.formatTimeLeft(level, usePerHour))
            end
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
        end
        holder.warnState = state
    end

    for _, group in ipairs(spec.groups) do
        check(group, group.hopper.label, group.fillLevel, getGroupUsePerHour(placeable, group))
    end

    local strawLevel = getStrawLevel(placeable)
    if strawLevel ~= nil then
        spec.straw = spec.straw or {}
        check(spec.straw, "straw", strawLevel, getStrawUsePerHour(placeable))
    end
end

-- Node the robot drops its feed from (its discharge door), for the food line in the feed alley
local function getDropNode(robot, spec)
    if spec.dropNode == nil then
        local robotNode = robot.robot ~= nil and robot.robot.node or nil
        if robotNode == nil then
            return nil
        end

        local function find(node)
            if getName(node) == "effectGrainDoorRight" then
                return node
            end
            for i = 0, getNumOfChildren(node) - 1 do
                local found = find(getChildAt(node, i))
                if found ~= nil then
                    return found
                end
            end
            return nil
        end
        spec.dropNode = find(robotNode) or robotNode
    end
    return spec.dropNode
end

-- Puts amount liters of the robot's load into the barn (server), shared over the groups by what is left of each.
-- With a node the food lands there (the food line in the alley), without one where the base game puts it.
function PlaceablePigFeedRobot.dropLoad(placeable, spec, amount, node)
    if spec.loadTotal <= 0 or amount <= 0 then
        return
    end
    amount = math.min(amount, spec.loadTotal)

    local fillPositionData = node ~= nil and {node=node, width=1, length=1} or nil
    local farmId = placeable:getOwnerFarmId()
    local returned = false
    local total = spec.loadTotal
    for i, group in ipairs(spec.groups) do
        local load = spec.load[i] or 0
        if load > 0 then
            local part = math.min(amount * load / total, load)
            local added = placeable:addFood(farmId, part, group.foodFillType, fillPositionData, nil, nil) or 0
            spec.load[i] = load - part
            if added < part then
                -- barn full: back into the hopper
                group.fillLevel = math.min(group.fillLevel + part - added, group.capacity)
                returned = true
            end
        end
    end

    spec.loadTotal = 0
    for i in ipairs(spec.groups) do
        if (spec.load[i] or 0) < 0.001 then
            spec.load[i] = 0
        end
        spec.loadTotal = spec.loadTotal + spec.load[i]
    end

    if returned then
        placeable:raiseDirtyFlags(spec.dirtyFlag)
        PlaceablePigFeedRobot.updateBinVisuals(placeable, spec)
    end
end

function PlaceablePigFeedRobot.flushLoad(placeable, spec, node)
    PlaceablePigFeedRobot.dropLoad(placeable, spec, spec.loadTotal, node)
end

-- Every frame while the robot has a load (server): drops it in step with the robot's way along the feeding spline
PlaceablePigFeedRobot.LOAD_TIMEOUT = 5 * 60 * 1000

function PlaceablePigFeedRobot.updateLoad(placeable, spec, dt)
    if spec.loadTotal <= 0 then
        return
    end

    local robot = getRobot(placeable)
    if robot == nil or robot.getFeedingFactor == nil then
        PlaceablePigFeedRobot.flushLoad(placeable, spec, nil)
        return
    end

    local state = robot.state or {}
    if robot.stateIndex ~= nil and robot.stateIndex ~= state.PAUSED then
        spec.robotLeftPause = true
    end

    local ok, factor = pcall(robot.getFeedingFactor, robot)
    factor = ok and type(factor) == "number" and math.max(math.min(factor, 1), 0) or 0

    if factor > 0 then
        spec.robotSeenFeeding = true
        local dropped = spec.loadAtStart - spec.loadTotal
        local due = factor * spec.loadAtStart - dropped
        if due > 0 then
            PlaceablePigFeedRobot.dropLoad(placeable, spec, due, getDropNode(robot, spec))
        end
    elseif spec.robotSeenFeeding then
        -- feeding spline done: the rest goes where the robot left the alley
        PlaceablePigFeedRobot.flushLoad(placeable, spec, getDropNode(robot, spec))
        return
    end

    spec.loadAge = spec.loadAge + dt
    local roundDone = spec.robotLeftPause and robot.stateIndex == state.PAUSED
    if roundDone or spec.loadAge > PlaceablePigFeedRobot.LOAD_TIMEOUT then
        -- the robot didn't get to feed (held back or no feeding spline): the barn gets it anyway
        PlaceablePigFeedRobot.flushLoad(placeable, spec, nil)
    end
end

-- Asks the robot to drive its round (server). The base robot only starts from PAUSED and only while nobody is in
-- its detection zone, so a start that is held back stays pending and is retried from the watchdog.
function PlaceablePigFeedRobot.tryStartRobot(placeable, spec)
    local robot = getRobot(placeable)
    if robot == nil or robot.start == nil then
        spec.robotStartPending = false
        return
    end

    local state = robot.state or {}
    if robot.stateIndex ~= nil and state.PAUSED ~= nil and robot.stateIndex ~= state.PAUSED then
        -- still loading: keep waiting; anything else: the robot is already on its round
        if robot.stateIndex ~= state.LOADING then
            spec.robotStartPending = false
        end
        return
    end

    local ok, err = pcall(robot.start, robot)
    if not ok then
        Logging.warning(LOG_PREFIX .. "the feeding robot could not start: %s", tostring(err))
        spec.robotStartPending = false
        return
    end

    if robot.requestedStart == false and robot.stateIndex == state.PAUSED then
        -- someone is in its zone: try again
        return
    end

    spec.robotStartPending = false
end

-- The barn got its hourly update (normally or from the watchdog)
function PlaceablePigFeedRobot:onHourChanged(hour)
    if self.isServer then
        self[PlaceablePigFeedRobot.SPEC_TABLE_NAME].lastHourKey = getHourKey()
    end
end

function PlaceablePigFeedRobot:updateFeeding(superFunc)
    if self.isServer then
        PlaceablePigFeedRobot.feedFromHoppers(self)
    end
    return withEmptyRobotSpots(self, superFunc, self)
end

function PlaceablePigFeedRobot:updateInfo(superFunc, infoTable)
    superFunc(self, infoTable)

    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    local foodPerHour = 0
    for _, group in ipairs(spec.groups) do
        local usePerHour = getGroupUsePerHour(self, group)
        foodPerHour = foodPerHour + usePerHour
        group.info.text = string.format("%s l (%s)", formatLiters(group.fillLevel), PlaceablePigFeedRobot.formatTimeLeft(group.fillLevel, usePerHour))
        table.insert(infoTable, group.info)
    end

    local strawLevel = getStrawLevel(self)
    if strawLevel ~= nil then
        spec.infoStraw.text = PlaceablePigFeedRobot.formatTimeLeft(strawLevel, getStrawUsePerHour(self))
        table.insert(infoTable, spec.infoStraw)
    end

    spec.infoFoodUse.text = string.format("%s l / month", formatLiters(foodPerHour * getHoursPerMonth()))
    table.insert(infoTable, spec.infoFoodUse)

    if self.getGlobalProductionFactor ~= nil then
        spec.infoProductivity.text = string.format("%d %%", math.floor(self:getGlobalProductionFactor() * 100 + 0.5))
        table.insert(infoTable, spec.infoProductivity)
    end
end

-- Savegame: one entry per hopper, matched by its marker crop
function PlaceablePigFeedRobot:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    for i, group in ipairs(spec.groups) do
        local hopperKey = string.format("%s.hopper(%d)", key, i - 1)
        xmlFile:setString(hopperKey .. "#group", group.hopper.marker)
        -- feed the robot hasn't dropped yet is saved back in its hopper
        xmlFile:setFloat(hopperKey .. "#fillLevel", group.fillLevel + (spec.load[i] or 0))
        local fillTypeName = group.lastFillType ~= nil and g_fillTypeManager:getFillTypeNameByIndex(group.lastFillType) or nil
        if fillTypeName ~= nil then
            xmlFile:setString(hopperKey .. "#lastFillType", fillTypeName)
        end
    end
    -- the robot saves its spots too, but since 1.0.0.5 those only hold the copied bin visuals
    xmlFile:setString(key .. "#robotSpots", "visual")
end

function PlaceablePigFeedRobot:loadFromXMLFile(xmlFile, key)
    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    if xmlFile:getString(key .. "#robotSpots") == "visual" then
        spec.robotStockMoved = true
    end

    local i = 0
    while true do
        local hopperKey = string.format("%s.hopper(%d)", key, i)
        if not xmlFile:hasProperty(hopperKey) then
            break
        end

        local marker = xmlFile:getString(hopperKey .. "#group")
        local fillLevel = xmlFile:getFloat(hopperKey .. "#fillLevel") or 0
        local fillTypeName = xmlFile:getString(hopperKey .. "#lastFillType")
        for _, group in ipairs(spec.groups) do
            if group.hopper.marker == marker then
                group.fillLevel = math.min(math.max(fillLevel, 0), group.capacity)
                local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil
                if fillTypeIndex ~= nil and group.fillTypeSet[fillTypeIndex] then
                    group.lastFillType = fillTypeIndex
                end
            end
        end
        i = i + 1
    end
end

-- Multiplayer: clients get the hopper levels (info box, bins, warnings) and the crop last tipped (bin look)
local function writeGroups(streamId, spec)
    for _, group in ipairs(spec.groups) do
        streamWriteFloat32(streamId, group.fillLevel)
        streamWriteUIntN(streamId, group.lastFillType or 0, FillTypeManager.SEND_NUM_BITS)
    end
end

local function readGroups(streamId, spec)
    for _, group in ipairs(spec.groups) do
        group.fillLevel = streamReadFloat32(streamId)
        local fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        group.lastFillType = fillTypeIndex ~= 0 and fillTypeIndex or nil
    end
end

function PlaceablePigFeedRobot:onWriteStream(streamId, connection)
    writeGroups(streamId, self[PlaceablePigFeedRobot.SPEC_TABLE_NAME])
end

function PlaceablePigFeedRobot:onReadStream(streamId, connection)
    local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
    readGroups(streamId, spec)
    PlaceablePigFeedRobot.updateBinVisuals(self, spec)
end

function PlaceablePigFeedRobot:onWriteUpdateStream(streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
        if streamWriteBool(streamId, bit32.band(dirtyMask, spec.dirtyFlag) ~= 0) then
            writeGroups(streamId, spec)
        end
    end
end

function PlaceablePigFeedRobot:onReadUpdateStream(streamId, timestamp, connection)
    if connection:getIsServer() then
        local spec = self[PlaceablePigFeedRobot.SPEC_TABLE_NAME]
        if streamReadBool(streamId) then
            readGroups(streamId, spec)
            PlaceablePigFeedRobot.updateBinVisuals(self, spec)
            PlaceablePigFeedRobot.checkSupplies(self, spec)
        end
    end
end
