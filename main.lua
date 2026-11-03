
local HttpService = game:GetService("HttpService")

local CONFIG = {
    GitHubURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/games.json",
    CheckInterval = 300,
    RequestDelay = 2,
    SaveDirectory = "SavedInstances",
    SaveFile = "SavedInstances/update_history.json"
}

local function log(message)
    print("[UpdateMonitor] " .. message)
end

local function loadHistory()
    log("Loading timestamp history...")

    if not isfile(CONFIG.SaveFile) then
        log("No history found. Starting fresh.")
        return {}
    end

    local success, result = pcall(function()
        return HttpService:JSONDecode(readfile(CONFIG.SaveFile))
    end)

    if not success or type(result) ~= "table" then
        warn("[UpdateMonitor] Could not load history.")
        return nil
    end

    log("Loaded " .. tostring(#result) .. " history entries.")
    return result
end

local function saveHistory(history)
    log("Writing timestamp history...")

    local success, err = pcall(function()
        writefile(CONFIG.SaveFile, HttpService:JSONEncode(history))
    end)

    if not success then
        warn("[UpdateMonitor] History write failed: " .. tostring(err))
        return false
    end

    log("History saved successfully.")
    return true
end

local function request(url, description)
    log("REQUEST: " .. description)

    local success, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not success then
        warn("[UpdateMonitor] Request failed: " .. tostring(result))
        return nil
    end

    log("REQUEST SUCCESS: " .. description)
    return result
end

local function getUniverseId(placeId)
    log("Resolving PlaceId: " .. tostring(placeId))

    local result = request(
        "https://apis.roblox.com/universes/v1/places/"
        .. tostring(placeId) .. "/universe",
        "UniverseId lookup"
    )

    if not result then return nil end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or not data.universeId then
        warn("[UpdateMonitor] Invalid UniverseId response.")
        return nil
    end

    log("UniverseId: " .. tostring(data.universeId))
    return tostring(data.universeId)
end

local function getUpdate(universeId)
    log("Checking UniverseId: " .. universeId)

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
        warn("[UpdateMonitor] No experience information returned.")
        return nil
    end

    return data.data[1].updated
end

local function parseTimestamp(value)
    if type(value) ~= "string" then
        return nil
    end

    local success, date = pcall(function()
        return DateTime.fromIsoDate(value)
    end)

    if not success or not date then
        return nil
    end

    return date.UnixTimestampMillis
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
        warn("[UpdateMonitor] Invalid GitHub JSON.")
        return
    end

    log("Found " .. #games .. " games.")

    local history = loadHistory()
    if not history then return end

    for index, gameInfo in ipairs(games) do
        log("----------------------------------------")
        log("GAME " .. index .. "/" .. #games)
        log("Name: " .. tostring(gameInfo.name))

        if not gameInfo.placeId then
            warn("[UpdateMonitor] Missing PlaceId.")
            continue
        end

        local universeId = getUniverseId(gameInfo.placeId)
        if not universeId then
            log("Skipping: UniverseId unavailable.")
            continue
        end

        local updated = getUpdate(universeId)
        if not updated then
            log("Skipping: Update timestamp unavailable.")
            continue
        end

        local previous = history[universeId]

        if not previous then
            log("NEW: No previously recorded archive.")
            log("Current update: " .. updated)
            log("Needs archive: YES")

        else
            local currentTime = parseTimestamp(updated)
            local previousTime = parseTimestamp(previous)

            if not currentTime or not previousTime then
                warn("[UpdateMonitor] Invalid timestamp. Skipping comparison.")

            elseif currentTime > previousTime then
                log("UPDATE DETECTED!")
                log("Previous: " .. previous)
                log("Current: " .. updated)
                log("Needs archive: YES")

            else
                log("UNCHANGED: No newer update.")
                log("Needs archive: NO")
            end
        end

        task.wait(CONFIG.RequestDelay)
    end

    log("Finished checking all games.")
    log("========================================")
end

if not isfolder(CONFIG.SaveDirectory) then
    makefolder(CONFIG.SaveDirectory)
end

while true do
    local success, err = pcall(checkGames)

    if not success then
        warn("[UpdateMonitor] Cycle error: " .. tostring(err))
    end

    log("Next check in " .. CONFIG.CheckInterval .. " seconds.")
    task.wait(CONFIG.CheckInterval)
end
