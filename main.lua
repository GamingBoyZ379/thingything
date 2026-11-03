local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local CONFIG = {
    GamesURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/games.json",
    ScriptURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/main.lua",
    CheckInterval = 300,
    RequestDelay = 1,
    LoadWait = 15,      -- seconds to let the place stream in before saving
    MaxAttempts = 3,
    Dir = "SavedInstances",
    StateFile = "SavedInstances/state.json",
}

local function log(msg) print("[UpdateMonitor] " .. msg) end

local function fetchJson(url, label)
    local ok, body = pcall(game.HttpGet, game, url, true) -- true = skip Real's response cache
    if not ok then warn("[UpdateMonitor] " .. label .. " failed: " .. tostring(body)) return nil end
    local ok2, data = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok2 then warn("[UpdateMonitor] " .. label .. " bad JSON") return nil end
    return data
end

-- state = { archived = {[placeId] = updated}, attempts = {[placeId] = n}, universes = {[rootPlaceId] = universeId} }
local function loadState()
    local state = { archived = {}, attempts = {}, universes = {} }
    if isfile(CONFIG.StateFile) then
        local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG.StateFile)) end)
        if ok and type(data) == "table" then
            for k in pairs(state) do state[k] = data[k] or state[k] end
        else
            warn("[UpdateMonitor] State unreadable, starting fresh.")
        end
    end
    return state
end

local function saveState(state)
    local ok, err = pcall(writefile, CONFIG.StateFile, HttpService:JSONEncode(state))
    if not ok then warn("[UpdateMonitor] State write failed: " .. tostring(err)) end
end

local function toMillis(iso)
    local ok, dt = pcall(DateTime.fromIsoDate, iso)
    return ok and dt and dt.UnixTimestampMillis or nil
end

local function getUniverseId(state, placeId)
    local key = tostring(placeId)
    if state.universes[key] then return state.universes[key] end

    local data = fetchJson("https://apis.roblox.com/universes/v1/places/" .. key .. "/universe", "Universe lookup")
    if data and data.universeId then
        state.universes[key] = tostring(data.universeId)
        task.wait(CONFIG.RequestDelay)
        return state.universes[key]
    end
end

-- all places (root + subplaces) in a universe; falls back to the listed place if the lookup fails
local function getPlaces(universeId, fallbackPlaceId)
    local places, cursor = {}, nil
    repeat
        local url = ("https://develop.roblox.com/v1/universes/%s/places?limit=100&sortOrder=Asc"):format(universeId)
        if cursor then url = url .. "&cursor=" .. cursor end
        local data = fetchJson(url, "Places lookup")
        task.wait(CONFIG.RequestDelay)
        if not (data and type(data.data) == "table") then break end
        for _, p in ipairs(data.data) do
            table.insert(places, { id = p.id, name = p.name or tostring(p.id) })
        end
        cursor = data.nextPageCursor
    until not cursor

    if #places == 0 then
        warn("[UpdateMonitor] No places returned for universe " .. universeId .. ", using listed place only.")
        places[1] = { id = fallbackPlaceId, name = "Main" }
    end
    return places
end

local function needsArchive(state, key, updated)
    local prev = state.archived[key]
    if not prev then return true end
    local a, b = toMillis(updated), toMillis(prev)
    return a ~= nil and b ~= nil and a > b
end

local function findPending(state)
    local games = fetchJson(CONFIG.GamesURL, "games.json")
    if type(games) ~= "table" then return {} end

    local entries, ids = {}, {}
    for _, g in ipairs(games) do
        if g.placeId then
            local uid = getUniverseId(state, g.placeId)
            if uid then
                entries[uid] = { name = g.name or uid, rootPlaceId = g.placeId, universeId = uid }
                table.insert(ids, uid)
            end
        end
    end

    local pending = {}
    -- batch update lookup, 50 universes per request
    for i = 1, #ids, 50 do
        local chunk = table.concat(ids, ",", i, math.min(i + 49, #ids))
        local data = fetchJson("https://games.roblox.com/v1/games?universeIds=" .. chunk, "Update lookup")
        if data and data.data then
            for _, info in ipairs(data.data) do
                local e = entries[tostring(info.id)]
                if e then
                    for _, p in ipairs(getPlaces(e.universeId, e.rootPlaceId)) do
                        local key = tostring(p.id)
                        if needsArchive(state, key, info.updated) then
                            table.insert(pending, {
                                name = e.name .. " - " .. p.name,
                                placeId = p.id,
                                universeId = e.universeId,
                                key = key,
                                updated = info.updated,
                            })
                        end
                    end
                end
            end
        end
        task.wait(CONFIG.RequestDelay)
    end
    return pending
end

local function archive(state, entry)
    state.attempts[entry.key] = (state.attempts[entry.key] or 0) + 1
    saveState(state) -- persist the attempt before the risky part

    log("Archiving " .. entry.name)
    if not game:IsLoaded() then game.Loaded:Wait() end
    task.wait(CONFIG.LoadWait)

    local safeName = entry.name:gsub("[^%w%-_ ]", "")
    local ok, path = pcall(saveinstance, {
        FileName = ("%s_%s_%s"):format(safeName, entry.key, os.date("%Y%m%d")), -- no slashes
        Decompile = true,
        scriptcache = true,
        IgnoreDefaultProperties = true,
    })

    if ok and type(path) == "string" then
        state.archived[entry.key] = entry.updated
        state.attempts[entry.key] = nil
        log("Archived " .. entry.name .. " -> " .. path)
    else
        warn("[UpdateMonitor] saveinstance failed: " .. tostring(path))
    end
    saveState(state)
end

local function cycle()
    local state = loadState()
    local pending = findPending(state)
    saveState(state) -- keeps the universe cache

    log(#pending .. " place(s) need archiving.")

    -- archive the current place if it's pending
    for _, e in ipairs(pending) do
        if tostring(game.PlaceId) == e.key then
            archive(state, e)
            return
        end
    end

    -- otherwise hop to the next one
    for _, e in ipairs(pending) do
        if (state.attempts[e.key] or 0) < CONFIG.MaxAttempts then
            state.attempts[e.key] = (state.attempts[e.key] or 0) + 1
            saveState(state)
            log("Teleporting to " .. e.name)
            clear_teleport_queue() -- avoid stacked copies if a previous teleport failed
            queue_on_teleport(('loadstring(game:HttpGet("%s", true))()'):format(CONFIG.ScriptURL))
            TeleportService:Teleport(e.placeId)
            task.wait(30) -- teleport kills the script; this just stops the loop racing it
            return
        end
    end
end

if not isfolder(CONFIG.Dir) then makefolder(CONFIG.Dir) end

while true do
    local ok, err = pcall(cycle)
    if not ok then warn("[UpdateMonitor] Cycle error: " .. tostring(err)) end
    task.wait(CONFIG.CheckInterval)
end
