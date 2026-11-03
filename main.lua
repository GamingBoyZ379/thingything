local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local CONFIG = {
    GamesURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/games.json",
    ScriptURL = "https://raw.githubusercontent.com/GamingBoyZ379/thingything/main/monitor.lua", -- host this script here
    CheckInterval = 300,
    RequestDelay = 1,
    LoadWait = 15,      -- seconds to let the place stream in before saving
    MaxAttempts = 3,
    Dir = "SavedInstances",
    StateFile = "SavedInstances/state.json",
}

local function log(msg) print("[UpdateMonitor] " .. msg) end

local function fetchJson(url, label)
    local ok, body = pcall(game.HttpGet, game, url)
    if not ok then warn("[UpdateMonitor] " .. label .. " failed: " .. tostring(body)) return nil end
    local ok2, data = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok2 then warn("[UpdateMonitor] " .. label .. " bad JSON") return nil end
    return data
end

-- state = { archived = {[universeId] = updated}, attempts = {[universeId] = n}, universes = {[placeId] = universeId} }
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

local function needsArchive(state, universeId, updated)
    local prev = state.archived[universeId]
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
                entries[uid] = { name = g.name or uid, placeId = g.placeId, universeId = uid }
                table.insert(ids, uid)
            end
        end
    end

    local pending = {}
    -- batch update lookup, 50 ids per request
    for i = 1, #ids, 50 do
        local chunk = table.concat(ids, ",", i, math.min(i + 49, #ids))
        local data = fetchJson("https://games.roblox.com/v1/games?universeIds=" .. chunk, "Update lookup")
        if data and data.data then
            for _, info in ipairs(data.data) do
                local e = entries[tostring(info.id)]
                if e and needsArchive(state, e.universeId, info.updated) then
                    e.updated = info.updated
                    table.insert(pending, e)
                end
            end
        end
        task.wait(CONFIG.RequestDelay)
    end
    return pending
end

local function archive(state, entry)
    state.attempts[entry.universeId] = (state.attempts[entry.universeId] or 0) + 1
    saveState(state) -- persist the attempt before the risky part

    log("Archiving " .. entry.name)
    if not game:IsLoaded() then game.Loaded:Wait() end
    task.wait(CONFIG.LoadWait)

    local safeName = entry.name:gsub("[^%w%-_ ]", "")
    local ok, err = pcall(saveinstance, {
        FileName = ("%s/%s_%s_%s"):format(CONFIG.Dir, safeName, entry.universeId, os.date("%Y%m%d")),
    })

    if ok then
        state.archived[entry.universeId] = entry.updated
        state.attempts[entry.universeId] = nil
        log("Archived " .. entry.name)
    else
        warn("[UpdateMonitor] saveinstance failed: " .. tostring(err))
    end
    saveState(state)
end

local function cycle()
    local state = loadState()
    local pending = findPending(state)
    saveState(state) -- keeps the universe cache

    log(#pending .. " game(s) need archiving.")

    -- archive the current place if it's pending
    for _, e in ipairs(pending) do
        if tostring(game.GameId) == e.universeId then
            archive(state, e)
            return
        end
    end

    -- otherwise hop to the next one
    for _, e in ipairs(pending) do
        if (state.attempts[e.universeId] or 0) < CONFIG.MaxAttempts then
            state.attempts[e.universeId] = (state.attempts[e.universeId] or 0) + 1
            saveState(state)
            log("Teleporting to " .. e.name)
            queue_on_teleport(('loadstring(game:HttpGet("%s"))()'):format(CONFIG.ScriptURL))
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
