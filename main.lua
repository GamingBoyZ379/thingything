local HttpService = game:GetService("HttpService")

local CONFIG = {
    GitHubURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/games.json",
    CheckInterval = 300,
    RequestDelay = 2,
    SaveFile = "SavedInstances/update_history.json"
}

local function log(message)
    print("[UpdateMonitor] " .. message)
end

-- Load saved timestamps
local function loadHistory()
    log("Loading saved timestamp history...")

    if not isfile(CONFIG.SaveFile) then
        log("No previous history found. Starting fresh.")
        return {}
    end

    local success, result = pcall(function()
        return HttpService:JSONDecode(readfile(CONFIG.SaveFile))
    end)

    if not success then
        warn("[UpdateMonitor] Failed to read history: " .. tostring(result))
        return {}
    end

    log("Loaded saved timestamp history.")
    return result
end

-- Save timestamps
local function saveHistory(history)
    log("Saving timestamp history...")

    local success, err = pcall(function()
        writefile(CONFIG.SaveFile, HttpService:JSONEncode(history))
    end)

    if success then
        log("Timestamp history saved.")
    else
        warn("[UpdateMonitor] Failed to save history: " .. tostring(err))
    end
end

local function request(url, description)
    log("REQUEST: " .. description)

    local success, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not success then
        warn("[UpdateMonitor] REQUEST FAILED: " .. tostring(result))
        return nil
    end

    log("REQUEST SUCCESS: " .. description)
    return result
end

local function getUniverseId(placeId)
    log("Resolving UniverseId for PlaceId " .. placeId)

    local result = request(
        "https://apis.roblox.com/universes/v1/places/"
        .. placeId .. "/universe",
        "UniverseId lookup"
    )

    if not result then return nil end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or not data.universeId then
        warn("[UpdateMonitor] Invalid UniverseId response")
        return nil
    end

    log("UniverseId found: " .. data.universeId)
    return tostring(data.universeId)
end

local function getUpdate(universeId)
    log("Checking UniverseId " .. universeId)

    local result = request(
        "https://games.roblox.com/v1/games?universeIds="
        .. universeId,
        "Experience update lookup"
    )

    if not result then return nil end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or not data.data or not data.data[1] then
        warn("[UpdateMonitor] No experience information returned")
        return nil
    end

    return data.data[1].updated
end

local function checkGames()
    log("========================================")
    log("Starting GitHub refresh")

    local result = request(CONFIG.GitHubURL, "Downloading games.json")
    if not result then return end

    local success, games = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or type(games) ~= "table" then
        warn("[UpdateMonitor] Invalid GitHub JSON")
        return
    end

    log("Found " .. #games .. " games")

    local history = loadHistory()

    for index, gameInfo in ipairs(games) do
        log("----------------------------------------")
        log("GAME " .. index .. "/" .. #games)
        log("Name: " .. tostring(gameInfo.name))

        if not gameInfo.placeId then
            warn("[UpdateMonitor] Missing PlaceId")
            continue
        end

        local universeId = getUniverseId(gameInfo.placeId)

        if not universeId then
            log("Skipping: UniverseId unavailable")
            continue
        end

        local updated = getUpdate(universeId)

        if not updated then
            log("Skipping: Update timestamp unavailable")
            continue
        end

        local previous = history[universeId]

        if not previous then
            log("NEW GAME: No saved timestamp exists.")
            history[universeId] = updated

        elseif previous ~= updated then
            log("UPDATE DETECTED!")
            log("Previous: " .. tostring(previous))
            log("Current:  " .. tostring(updated))

            history[universeId] = updated

        else
            log("UNCHANGED: No new update.")
        end

        task.wait(CONFIG.RequestDelay)
    end

    saveHistory(history)

    log("Finished checking all games")
    log("========================================")
end

-- Create storage folder
if not isfolder("SavedInstances") then
    makefolder("SavedInstances")
end

while true do
    checkGames()

    log("Next check in " .. CONFIG.CheckInterval .. " seconds")
    task.wait(CONFIG.CheckInterval)
end
