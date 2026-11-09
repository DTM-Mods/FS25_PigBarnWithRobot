-- Registers a PIGFOOD feeding robot recipe so the GEA robot can feed pigs.
--
-- The base game only defines a FORAGE recipe (cow TMR), and a pig barn rejects FORAGE.
-- The recipe is built from the map's own PIGFOOD mixture, so its crops and ratios match
-- whatever the map (or a map mod) feeds pigs. The robot puts PIGFOOD into the barn,
-- and the barn splits it back into the pig food groups.

PigFeedRecipe = {}

local LOG_PREFIX = "PigBarnWithRobot: "
local modDirectory = g_currentModDirectory

local function getFillTypeTitle(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType ~= nil and fillType.title ~= nil then
        return fillType.title
    end
    return g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or "?"
end

-- Uses the pig food group title (e.g. "Grain") when the animal food data is reachable, else lists the crops
local function getIngredientTitle(foodSystem, ingredient)
    local animalTypeIndex = nil
    local mission = foodSystem.mission or g_currentMission
    if mission ~= nil and mission.animalSystem ~= nil and mission.animalSystem.getTypeIndexByName ~= nil then
        animalTypeIndex = mission.animalSystem:getTypeIndexByName("PIG")
    end

    if animalTypeIndex ~= nil and foodSystem.getAnimalFood ~= nil then
        local animalFood = foodSystem:getAnimalFood(animalTypeIndex)
        if animalFood ~= nil and animalFood.groups ~= nil then
            for _, group in pairs(animalFood.groups) do
                for _, fillTypeIndex in pairs(group.fillTypes) do
                    if fillTypeIndex == ingredient.fillTypes[1] and group.title ~= nil then
                        return group.title
                    end
                end
            end
        end
    end

    local titles = {}
    for _, fillTypeIndex in ipairs(ingredient.fillTypes) do
        table.insert(titles, getFillTypeTitle(fillTypeIndex))
    end
    return table.concat(titles, ", ")
end

-- One recipe ingredient per PIGFOOD mixture group (base feed, grain, protein, root crops), with the same shares
function PigFeedRecipe.getRecipeIngredients(foodSystem, mixture)
    local ingredients = {}
    for _, mixtureIngredient in ipairs(mixture.ingredients) do
        table.insert(ingredients, {
            fillTypes = mixtureIngredient.fillTypes,
            weight = mixtureIngredient.weight,
            title = getIngredientTitle(foodSystem, mixtureIngredient)
        })
    end
    return ingredients
end

function PigFeedRecipe.addRecipe(foodSystem)
    local pigFoodIndex = g_fillTypeManager:getFillTypeIndexByName("PIGFOOD")
    if pigFoodIndex == nil then
        Logging.error(LOG_PREFIX .. "fill type PIGFOOD not found, the pig feeding robot will not work")
        return
    end

    if foodSystem:getRecipeByFillTypeIndex(pigFoodIndex) ~= nil then
        -- the map or another mod already defines one
        return
    end

    local mixture = foodSystem:getMixtureByFillType(pigFoodIndex)
    if mixture == nil or mixture.ingredients == nil or #mixture.ingredients == 0 then
        Logging.error(LOG_PREFIX .. "the map has no PIGFOOD mixture, the pig feeding robot will not work")
        return
    end

    -- Feed the recipe through the game's own parser so it ends up in the same shape as the map's recipes.
    -- The xml only lives in memory, it is never saved.
    local xmlFile = XMLFile.create("pigFeedRecipe", modDirectory .. "pigFeedRecipe.xml", "animalFood", AnimalFoodSystem.xmlSchema)
    if xmlFile == nil then
        Logging.error(LOG_PREFIX .. "could not create the recipe xml")
        return
    end

    local recipeKey = "animalFood.recipes.recipe(0)"
    xmlFile:setString(recipeKey .. "#fillType", "PIGFOOD")

    local ingredients = PigFeedRecipe.getRecipeIngredients(foodSystem, mixture)
    for i, ingredient in ipairs(ingredients) do
        local names = {}
        for _, fillTypeIndex in ipairs(ingredient.fillTypes) do
            table.insert(names, g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex))
        end

        -- the parser uses (max - min) as the ingredient's share, so max = weight in percent
        local key = string.format("%s.ingredient(%d)", recipeKey, i - 1)
        xmlFile:setString(key .. "#name", "pigFeed" .. i)
        xmlFile:setString(key .. "#title", ingredient.title)
        xmlFile:setInt(key .. "#minPercentage", 0)
        xmlFile:setInt(key .. "#maxPercentage", math.max(1, MathUtil.round(ingredient.weight * 100)))
        xmlFile:setString(key .. "#fillTypes", table.concat(names, " "))
    end

    local mission = foodSystem.mission or g_currentMission
    foodSystem:loadRecipes(xmlFile, mission ~= nil and mission.baseDirectory or nil)
    xmlFile:delete()

    if foodSystem:getRecipeByFillTypeIndex(pigFoodIndex) ~= nil then
        Logging.info(LOG_PREFIX .. "registered PIGFOOD feeding robot recipe (%d ingredients)", #ingredients)
    else
        Logging.error(LOG_PREFIX .. "failed to register the PIGFOOD recipe, the pig feeding robot will not work")
    end
end

if AnimalFoodSystem ~= nil and AnimalFoodSystem.loadMapData ~= nil then
    AnimalFoodSystem.loadMapData = Utils.overwrittenFunction(AnimalFoodSystem.loadMapData, function(self, superFunc, ...)
        local success = superFunc(self, ...)
        if success ~= false then
            PigFeedRecipe.addRecipe(self)
        end
        return success
    end)
else
    Logging.error(LOG_PREFIX .. "AnimalFoodSystem not found, the pig feeding robot will not work")
end
