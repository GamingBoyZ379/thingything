local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local AssetService = game:GetService("AssetService")

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

-- state = {
--   archived  = {[placeId] = updated},
--   attempts  = {[placeId] = n},
--   universes = {[rootPlaceId] = universeId},
--   places    = {[universeId] = { {id=, name=}, ... }},  -- from GetGamePlacesAsync
-- }
local function loadState()
    local state = { archived = {}, attempts = {}, universes = {}, places = {} }
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

-- cache every place of the game we're currently in
local function enumeratePlaces(state)
    local ok, err = pcall(function()
        local pages = AssetService:GetGamePlacesAsync()
        local list = {}
        while true do
            for _, p in ipairs(pages:GetCurrentPage()) do
                table.insert(list, { id = p.PlaceId, name = p.Name })
            end
            if pages.IsFinished then break end
            pages:AdvanceToNextPageAsync()
        end
        state.places[tostring(game.GameId)] = list
        log("Cached " .. #list .. " place(s) for universe " .. tostring(game.GameId))
    end)
    if not ok then warn("[UpdateMonitor] GetGamePlacesAsync failed: " .. tostring(err)) end
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
                local gname = g.name or uid
                local places, seen = {}, {}
                local function add(id, name)
                    local key = tostring(id)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(places, { id = id, key = key, name = name })
                    end
                end
                add(g.placeId, gname) -- main place always included
                for _, p in ipairs(state.places[uid] or {}) do
                    add(p.id, gname .. " - " .. tostring(p.name))
                end

                entries[uid] = { universeId = uid, places = places }
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
                    for _, p in ipairs(e.places) do
                        if needsArchive(state, p.key, info.updated) then
                            table.insert(pending, {
                                name = p.name,
                                placeId = p.id,
                                universeId = e.universeId,
                                key = p.key,
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
    if not game:IsLoaded() then game.Loaded:Wait() end
    enumeratePlaces(state) -- before findPending so new subplaces count immediately
    local pending = findPending(state)
    saveState(state) -- keeps universe + places cache

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
