local HttpService = game:GetService("HttpService")

local CONFIG = {
    GitHubURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/games.json",
    CheckInterval = 300,
    RequestDelay = 2,
}

local function log(message)
    print("[UpdateMonitor] " .. message)
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

    if not result then
        warn("[UpdateMonitor] Could not resolve UniverseId")
        return nil
    end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or not data.universeId then
        warn("[UpdateMonitor] Invalid UniverseId response")
        return nil
    end

    log("UniverseId found: " .. data.universeId)
    return data.universeId
end

local function getUpdate(universeId)
    log("Checking update information for UniverseId " .. universeId)

    local result = request(
        "https://games.roblox.com/v1/games?universeIds="
        .. universeId,
        "Experience update lookup"
    )

    if not result then
        return nil
    end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or not data.data or not data.data[1] then
        warn("[UpdateMonitor] No experience information returned")
        return nil
    end

    local updated = data.data[1].updated

    log("Latest update: " .. tostring(updated))
    return updated
end

local function checkGames()
    log("========================================")
    log("Starting GitHub refresh")

    local result = request(CONFIG.GitHubURL, "Downloading games.json")

    if not result then
        warn("[UpdateMonitor] GitHub download failed")
        return
    end

    log("Parsing GitHub JSON")

    local success, games = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or type(games) ~= "table" then
        warn("[UpdateMonitor] Invalid GitHub JSON")
        return
    end

    log("Found " .. #games .. " games")

    for index, gameInfo in ipairs(games) do
        log("----------------------------------------")
        log("GAME " .. index .. "/" .. #games)
        log("Name: " .. tostring(gameInfo.name))
        log("PlaceId: " .. tostring(gameInfo.placeId))

        if not gameInfo.placeId then
            warn("[UpdateMonitor] Missing PlaceId, skipping")
            continue
        end

        local universeId = getUniverseId(gameInfo.placeId)

        if not universeId then
            warn("[UpdateMonitor] Skipping game: UniverseId unavailable")
            continue
        end

        local updated = getUpdate(universeId)

        if updated then
            log("CHECK COMPLETE: " .. gameInfo.name)
            log("Last updated: " .. updated)
        else
            warn("[UpdateMonitor] Update check failed for " .. gameInfo.name)
        end

        task.wait(CONFIG.RequestDelay)
    end

    log("========================================")
    log("Finished checking all games")
end

while true do
    log("Beginning update-monitor cycle")

    checkGames()

    log("Next check in " .. CONFIG.CheckInterval .. " seconds")
    task.wait(CONFIG.CheckInterval)
end
