local HttpService = game:GetService("HttpService")

local CONFIG = {
    GitHubURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/games.json",
    CheckInterval = 300,
}

local function request(url)
    local success, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not success then
        warn("[UpdateMonitor] Request failed:", result)
        return nil
    end

    return result
end

local function getUniverseId(placeId)
    local result = request(
        "https://apis.roblox.com/universes/v1/places/"
        .. placeId .. "/universe"
    )

    if not result then return nil end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    return success and data.universeId or nil
end

local function getUpdate(universeId)
    local result = request(
        "https://games.roblox.com/v1/games?universeIds="
        .. universeId
    )

    if not result then return nil end

    local success, data = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success or not data.data or not data.data[1] then
        return nil
    end

    return data.data[1].updated
end

local function checkGames()
    local result = request(CONFIG.GitHubURL)
    if not result then return end

    local success, games = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if not success then
        warn("[UpdateMonitor] Invalid GitHub JSON")
        return
    end

    for _, gameInfo in ipairs(games) do
        local universeId = getUniverseId(gameInfo.placeId)

        if universeId then
            local updated = getUpdate(universeId)

            if updated then
                print(
                    "[UpdateMonitor]",
                    gameInfo.name,
                    "Universe:",
                    universeId,
                    "Last updated:",
                    updated
                )
            end
        end

        task.wait(2)
    end
end

while true do
    checkGames()
    task.wait(CONFIG.CheckInterval)
end
