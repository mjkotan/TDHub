--[[
TD Hub v2.2 - [⏳] เอาชีวิตรอดในคืน TD (GameId 10424107160)
  - Lobby PlaceId: 114125816375987 (แสดงเฉพาะฟังก์ชัน Lobby + จัด Loadout อัตโนมัติ)
  - Match PlaceId: 102317593129301 (แสดงฟังก์ชันในด่าน: เลือกฐาน, หลายประตู, Auto Win AI, ESP)
  - Auto-Reload on Teleport: โหลดสคริปต์ซ้ำอัตโนมัติเมื่อเข้าด่าน/กลับ Lobby ไม่ให้ UI หาย
  - UI: FluentStudio (https://github.com/mjkotan/FluentStudio)
]]

if not game:IsLoaded() then
    pcall(function() game.Loaded:Wait() end)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

while not Players.LocalPlayer do
    task.wait(0.1)
end
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    ExpectedGameId = 10424107160,
    PlaceLobby = 114125816375987,
    PlaceMatch = 102317593129301,
    ToggleKey = Enum.KeyCode.Delete,
    InterfaceFolder = "TDHub",
    ConfigFolder = "TDHub/configs",
    StateFile = "TDHub/hub_state.json",
    AutoReloadFile = "TDHub/TD_Hub.lua",
    Libraries = {
        LocalFolder = "TDHub/ui",
        FallbackFolder = "TMLGame/ui",
        Fluent = "https://raw.githubusercontent.com/mjkotan/FluentStudio/main/build/FluentStudio.luau",
        SaveManager = "https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua",
        InterfaceManager = "https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua",
    },
}

local genv = (type(getgenv) == "function" and getgenv()) or _G
genv.__TDHub_TeleportQueued = false

if type(genv.TDHub_Cleanup) == "function" then
    pcall(genv.TDHub_Cleanup)
    genv.TDHub_Cleanup = nil
end
if genv.__TDHub and type(genv.__TDHub.Destroy) == "function" then
    pcall(genv.__TDHub.Destroy)
end

if game.GameId ~= 0 and game.GameId ~= CONFIG.ExpectedGameId then
    warn(string.format("[TDHub] GameId %s is outside expected GameId %s; some features may not apply.", tostring(game.GameId), tostring(CONFIG.ExpectedGameId)))
end

-- TowerDefenseRemotes exists in Lobby too; check Match-only instances instead
local function detectMatch()
    return game.PlaceId == CONFIG.PlaceMatch
        or workspace:FindFirstChild("PlacedTowers") ~= nil
        or ReplicatedStorage:FindFirstChild("TowerConfig") ~= nil
end

if game.PlaceId == CONFIG.PlaceMatch then
    local deadline = os.clock() + 12
    while os.clock() < deadline do
        local gm = workspace:FindFirstChild("GameMap")
        local hs = gm and gm:FindFirstChild("Houses")
        if workspace:FindFirstChild("PlacedTowers") ~= nil
            and ReplicatedStorage:FindFirstChild("TowerConfig") ~= nil
            and hs ~= nil and #hs:GetChildren() > 0 then
            break
        end
        task.wait(0.15)
    end
end

local IS_MATCH = detectMatch()
local IS_LOBBY = not IS_MATCH

local Hub = {
    alive = true,
    conns = {},
    cleanups = {},
    Window = nil,
    Fluent = nil,
}
genv.__TDHub = Hub

local function track(c)
    if c then
        Hub.conns[#Hub.conns + 1] = c
    end
    return c
end

local function superseded()
    return not Hub.alive or genv.__TDHub ~= Hub
end

-- ---------------------------------------------------------------- libraries (FluentStudio + Addons)
local function patchFluentBundle(code)
    if type(code) == "string" and code:find("%[FluentStudio Bundle%]") then
        code = code:gsub(
            "local result = loader%(__makeNode%(path%), __require%)",
            "local __sp = if resolved == 'init' then '' elseif string.sub(resolved, -5) == '/init' then string.sub(resolved, 1, -6) else resolved\n\tlocal result = loader(__makeNode(__sp), __require)"
        )
    end
    return code
end

local function loadLibrary(url, localName)
    local source, from = nil, "web"
    local path = CONFIG.Libraries.LocalFolder .. "/" .. localName
    local altPath = CONFIG.Libraries.FallbackFolder .. "/" .. localName

    if type(isfile) == "function" and type(readfile) == "function" then
        for _, candidate in ipairs({ path, altPath }) do
            local okExists, exists = pcall(isfile, candidate)
            if okExists and exists then
                local okRead, text = pcall(readfile, candidate)
                if okRead and type(text) == "string" and #text > 1000 then
                    source, from = text, "local file " .. candidate
                    break
                end
            end
        end
    end

    local function tryLoad(codeText)
        local fn, compileErr = loadstring(patchFluentBundle(codeText), "=" .. localName)
        if not fn then
            return false, "compile: " .. tostring(compileErr)
        end
        local okRun, lib = pcall(fn)
        if okRun and type(lib) ~= "table" then
            return false, "returned " .. typeof(lib) .. " instead of a table"
        end
        return okRun, lib
    end

    local ok, result = false, nil
    if source then
        ok, result = tryLoad(source)
    end
    if not ok then
        if source then
            from = "web (local failed: " .. tostring(result) .. ")"
        end
        for attempt = 1, 3 do
            local okHttp, body = pcall(function() return game:HttpGet(url) end)
            if okHttp and type(body) == "string" and #body > 1000 then
                ok, result = tryLoad(body)
                if ok then
                    if type(writefile) == "function" then
                        pcall(function()
                            if type(makefolder) == "function" then
                                makefolder(CONFIG.InterfaceFolder)
                                makefolder(CONFIG.Libraries.LocalFolder)
                            end
                            writefile(path, body)
                        end)
                    end
                    break
                end
            else
                ok, result = false, "HttpGet: " .. tostring(body)
            end
            if attempt < 3 then
                task.wait(0.5)
            end
        end
    elseif from:find(altPath, 1, true) and type(writefile) == "function" and type(isfile) == "function" then
        pcall(function()
            local okEx, ex = pcall(isfile, path)
            if okEx and not ex then
                if type(makefolder) == "function" then
                    makefolder(CONFIG.InterfaceFolder)
                    makefolder(CONFIG.Libraries.LocalFolder)
                end
                writefile(path, source)
            end
        end)
    end

    if not ok then
        warn("[TDHub] could not load " .. localName .. ": " .. tostring(result))
        return nil
    end
    print("[TDHub] " .. localName .. " loaded from " .. from)
    return result
end

local LearnBox = genv.TDHub_LearnBox or { handler = nil }
genv.TDHub_LearnBox = LearnBox

function Hub.Destroy()
    if not Hub.alive then
        return
    end
    Hub.alive = false
    LearnBox.handler = nil
    for _, c in ipairs(Hub.conns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(Hub.conns)
    for _, fn in ipairs(Hub.cleanups) do
        pcall(fn)
    end
    table.clear(Hub.cleanups)
    if Hub.Fluent then
        Hub.Fluent.Unloaded = true
    end
    if Hub.Window then
        pcall(function() Hub.Window:Destroy() end)
        Hub.Window = nil
    end
    if genv.__TDHub == Hub then
        genv.__TDHub = nil
    end
    if genv.TDHub_Cleanup == Hub.Destroy then
        genv.TDHub_Cleanup = nil
    end
end
genv.TDHub_Cleanup = Hub.Destroy

local FluentStudio = loadLibrary(CONFIG.Libraries.Fluent, "FluentStudio.luau")
local SaveManager = loadLibrary(CONFIG.Libraries.SaveManager, "SaveManager.lua")
local InterfaceManager = loadLibrary(CONFIG.Libraries.InterfaceManager, "InterfaceManager.lua")
if superseded() then
    return
end
if not (FluentStudio and type(FluentStudio.CreateWindow) == "function") then
    warn("[TDHub] FluentStudio did not load (no CreateWindow), stopping")
    Hub.Destroy()
    return
end

-- ---------------------------------------------------------------- state & common helpers
local State = {
    AutoReload = true,
    AntiAFK = true,
    Learn = false,
    -- Lobby
    LoadoutPreset = "ดีที่สุดจากคลัง (ปั๊มเงิน+แรง+ถูก)",
    -- Match visuals & strategy (Auto-enabled across matches & persisted)
    MonsterESP = false,
    ESPMax = 25,
    AutoWin = true,
    WinStyle = "Balanced (ปั๊มเงิน+แรง+ถูก)",
    AutoMoveToCell = true,
    AutoReplaceWeak = true,
    AutoClaimBase = true,
    BasePreference = "1 ประตู + พื้นที่กว้างสุด (ชนะง่าย)",
    SelectedBase = nil,
    -- Granular match toggles
    AutoPlace = false,
    PlaceType = nil,
    AutoUpgrade = false,
    UpgradeOrder = "Cheapest first",
    UpgradeInterval = 0.6,
    CashReserve = 0,
    AutoBank = false,
    BankPct = 90,
    AutoGolemForge = false,
    AutoRepair = false,
    RepairBelow = 50,
    AutoDoorUp = false,
    AutoFree2X = true,
    AutoPlayAgain = false,
    AutoSpeed = false,
    SpeedTarget = "สูงสุดที่มี (4x->3x->2x)",
    AutoPvPDraft = true,
    PvPBanStyle = "แบนตัวเมต้า (เว้นตัวเก่งของเรา)",
    PvPCustomBans = "GolemForge,DivineBank,MortarMachine,CrusherTower",
    PvPSendMode = "สมดุล Eco + Rush ชนะไว",
    AutoPvPAbility = true,
    AutoAcceptTeamUp = "เฉพาะเพื่อน (Friends)",
    AutoDoorTargetUp = true,
}

local PERSIST_KEYS = {
    "AutoReload", "AntiAFK", "LoadoutPreset",
    "MonsterESP", "ESPMax", "AutoWin", "WinStyle",
    "AutoMoveToCell", "AutoReplaceWeak", "AutoClaimBase", "BasePreference",
    "AutoPlace", "AutoUpgrade", "UpgradeOrder", "UpgradeInterval", "CashReserve",
    "AutoBank", "BankPct", "AutoGolemForge", "AutoRepair", "RepairBelow",
    "AutoDoorUp", "AutoFree2X", "AutoPlayAgain", "AutoSpeed", "SpeedTarget",
    "AutoPvPDraft", "PvPBanStyle", "PvPCustomBans", "PvPSendMode", "AutoPvPAbility",
    "AutoAcceptTeamUp", "AutoDoorTargetUp",
}

local VALID_PERSIST_CHOICES = {
    PvPBanStyle = {
        ["แบนตัวเมต้า (เว้นตัวเก่งของเรา)"] = true,
        ["แบนตัวเมต้าสูงสุด (ทุกตัว)"] = true,
    },
    PvPSendMode = {
        ["สมดุล Eco + Rush ชนะไว"] = true,
        ["ปั๊ม Eco เน้นรายได้"] = true,
        ["สาย Rush ถล่มประตูไว"] = true,
        ["ปิด (ไม่ส่งมอน)"] = true,
    },
    WinStyle = {
        ["Balanced (ปั๊มเงิน+แรง+ถูก)"] = true,
        ["Eco & MoneyRush (ตั้งฐานปั๊มเงินไว)"] = true,
        ["Cheap DPS Rush (วางป้อมถูกแรงไว)"] = true,
    },
    BasePreference = {
        ["1 ประตู + พื้นที่กว้างสุด (ชนะง่าย)"] = true,
        ["ฐานว่างใกล้สุด"] = true,
        ["ฐาน 1 ประตู (ว่าง)"] = true,
        ["ฐานหลายประตู (ว่าง)"] = true,
        ["ตามที่เลือกใน Dropdown"] = true,
    },
    SpeedTarget = {
        ["สูงสุดที่มี (4x->3x->2x)"] = true,
        ["2x"] = true,
        ["3x (ต้องมี VIP)"] = true,
        ["4x (ต้องมีเวลา 4x)"] = true,
        ["1x (ปกติ)"] = true,
    },
    LoadoutPreset = {
        ["ดีที่สุดจากคลัง (ปั๊มเงิน+แรง+ถูก)"] = true,
        ["ปั๊มเงิน + AoE + บัฟ (ชนะโหมดยาก)"] = true,
        ["งบประหยัดต้นเกม (ผ่านง่าย)"] = true,
    },
    AutoAcceptTeamUp = {
        ["เฉพาะเพื่อน (Friends)"] = true,
        ["ทุกคน (Anyone)"] = true,
        ["ปิด (ไม่รับใคร)"] = true,
    },
    UpgradeOrder = {
        ["Cheapest first"] = true,
        ["Income towers first"] = true,
        ["Lowest level first"] = true,
        ["Most expensive first"] = true,
    },
}

local stateLoaded = false
local function saveHubState()
    if not stateLoaded then return end
    if type(writefile) ~= "function" then return end
    local payload = {}
    for _, k in ipairs(PERSIST_KEYS) do
        local v = State[k]
        if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
            payload[k] = v
        end
    end
    pcall(function()
        if type(makefolder) == "function" then
            makefolder(CONFIG.InterfaceFolder)
        end
        writefile(CONFIG.StateFile, HttpService:JSONEncode(payload))
    end)
end

local function loadHubState()
    local hadFile = false
    if type(isfile) == "function" and type(readfile) == "function" then
        local okEx, ex = pcall(isfile, CONFIG.StateFile)
        if okEx and ex then
            local okRead, raw = pcall(readfile, CONFIG.StateFile)
            if okRead and type(raw) == "string" and #raw > 2 then
                local okDec, tbl = pcall(function() return HttpService:JSONDecode(raw) end)
                if okDec and type(tbl) == "table" then
                    hadFile = true
                    for _, k in ipairs(PERSIST_KEYS) do
                        local v = tbl[k]
                        if v ~= nil and type(v) == type(State[k]) then
                            local valid = true
                            if VALID_PERSIST_CHOICES[k] then
                                valid = (VALID_PERSIST_CHOICES[k][v] == true)
                            end
                            if valid then
                                State[k] = v
                            end
                        end
                    end
                end
            end
        end
    end
    stateLoaded = true
    saveHubState()
end
loadHubState()

local function setState(key, val)
    if State[key] == val then return end
    State[key] = val
    saveHubState()
end

local function num(v)
    return type(v) == "number" and v or 0
end

local function attr(name)
    return LocalPlayer and LocalPlayer:GetAttribute(name)
end

local function hui()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and typeof(h) == "Instance" then
            return h
        end
    end
    local okCg, cg = pcall(function() return game:GetService("CoreGui") end)
    if okCg and typeof(cg) == "Instance" then
        return cg
    end
    return LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

-- Queue auto-reload across Place teleports (Lobby <-> Match)
local qotFn = (type(queue_on_teleport) == "function" and queue_on_teleport)
    or (type(queueonteleport) == "function" and queueonteleport)
if qotFn then
    track(LocalPlayer.OnTeleport:Connect(function(tpState)
        if not (Hub.alive and State.AutoReload) then return end
        if (tpState == Enum.TeleportState.Started or tpState == Enum.TeleportState.InProgress) and not genv.__TDHub_TeleportQueued then
            if type(isfile) == "function" and isfile(CONFIG.AutoReloadFile) then
                genv.__TDHub_TeleportQueued = true
                pcall(qotFn, string.format([[
                    task.wait(1.0)
                    if type(isfile) == "function" and type(readfile) == "function" and isfile(%q) then
                        local fn = loadstring(readfile(%q), "=TDHub_AutoReload")
                        if fn then pcall(fn) end
                    end
                ]], CONFIG.AutoReloadFile, CONFIG.AutoReloadFile))
            end
        end
    end))
end

-- ---------------------------------------------------------------- learn mode (read-only)
local Learned, LearnCount, LearnOrder = {}, {}, {}

local function describe(v, depth)
    local t = typeof(v)
    if t == "string" then
        return string.format("%q", #v > 60 and (string.sub(v, 1, 60) .. "...") or v)
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "Vector3" or t == "CFrame" or t == "Vector2" or t == "Color3" or t == "EnumItem" then
        return t .. "(" .. tostring(v) .. ")"
    elseif t == "Instance" then
        local parts, node, n = {}, v, 0
        while node and node ~= game and n < 6 do
            table.insert(parts, 1, node.Name)
            node = node.Parent
            n += 1
        end
        return "Instance(" .. table.concat(parts, ".") .. ")"
    elseif t == "table" then
        if depth >= 2 then return "{...}" end
        local out, c = {}, 0
        for k, x in pairs(v) do
            c += 1
            if c > 8 then out[#out + 1] = "..." break end
            out[#out + 1] = "[" .. describe(k, depth + 1) .. "]=" .. describe(x, depth + 1)
        end
        return "{" .. table.concat(out, ", ") .. "}"
    end
    return t
end

local function installLearnHook()
    if genv.TDHub_LearnHooked then return end
    if not (hookmetamethod and getnamecallmethod and newcclosure and checkcaller) then
        warn("[TDHub] hookmetamethod/getnamecallmethod/newcclosure/checkcaller missing")
        return
    end
    genv.TDHub_LearnHooked = true
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local h = LearnBox.handler
        if h then
            local m = getnamecallmethod()
            if (m == "FireServer" or m == "InvokeServer") and not checkcaller() then
                pcall(h, self, m, ...)
            end
        end
        return old(self, ...)
    end))
end

local LEARN_PARENTS = {
    TowerDefenseRemotes = true,
    Remotes = true,
    ClanRemotes = true,
    MatchQueueRemotes = true,
    PvPQueueRemotes = true,
}

LearnBox.handler = function(self, method, ...)
    if not (Hub.alive and State.Learn) then return end
    local parent = self.Parent
    if not parent then return end
    local pn = parent.Name
    if not LEARN_PARENTS[pn] then return end
    local name = self.Name
    LearnCount[name] = (LearnCount[name] or 0) + 1
    if LearnCount[name] > 3 then return end
    local a = table.pack(...)
    local parts = {}
    for i = 1, math.min(a.n, 10) do parts[i] = describe(a[i], 0) end
    if not Learned[name] then
        Learned[name] = {}
        LearnOrder[#LearnOrder + 1] = name
    end
    table.insert(Learned[name], pn .. "/" .. name .. ":" .. method .. "(" .. table.concat(parts, ", ") .. ")  n=" .. a.n)
end

local function saveLearned()
    local lines = { "# TD Hub learned calls, PlaceId " .. tostring(game.PlaceId) .. " (up to 3 samples per remote)" }
    for _, name in ipairs(LearnOrder) do
        for _, s in ipairs(Learned[name]) do lines[#lines + 1] = s end
    end
    if #lines == 1 then
        lines[2] = "# nothing recorded yet: turn Learn Mode on, then perform actions manually"
    end
    if type(writefile) ~= "function" then return false, "writefile unavailable", 0 end
    local ok, err = pcall(writefile, "TDHub_Learn.txt", table.concat(lines, "\n"))
    return ok, err, #lines - 1
end

-- ---------------------------------------------------------------- lobby owned tower analyzer & auto-loadout
local RARITY_RANK = {
    Divine = 6,
    Mythic = 5,
    Legendary = 4,
    Epic = 3,
    Rare = 2,
    Common = 1,
}

-- Verified power order for towers we inspected in TowerModelTemplates
local ECO_POWER_ORDER = {
    "MoneyMachine",    -- Cost 0! ($30->$5,000/5s)
    "VoidFarm",        -- Cost 500 ($55->$4,000/5s + pulse buff)
    "DivineBank",      -- Cost 200 ($4k->$1.4M bank)
    "VaultFarm",       -- Cost 300 ($12.67->$322.5/s, 2x faster cash than MiningCaveFarm Lv1-6!)
    "MiningCaveFarm",  -- Cost 240 ($6->$210/s, lim 26)
    "Farm",            -- Cost 30 ($6->$380/5s, cheap starter)
}

local SUPPORT_BUFF_ORDER = {
    "MilitaryBase",    -- DMG +15%->+40%, RNG +17%->+50%
    "ProtectorTower",
    "MedicalBase",
}

local COMBAT_HEAVY_ORDER = {
    "JuggernautTower",
    "WorldEnderTurret",
    "CrusherTower",
    "RailgunTurret",
    "LavaLauncher",
    "ScarecrowReaper",
    "BallistaTower",
    "FireSpitterTurret",
    "ToxicTurret",
    "TeslaTurret",
    "MissileTower",
    "FlamethrowerTurret",
    "SamuraiTower",
    "Turret",
    "CannonTower",
    "CrossbowTower",
}

local COMBAT_CHEAP_ORDER = {
    "CrossbowTower",       -- Cost 25, Range 39 (best starter DPS/cost)
    "Turret",              -- Cost 35, Minigun at Lv4
    "SamuraiTower",        -- Cost 100, fast melee
    "CannonTower",         -- Cost 150
    "FlamethrowerTurret",  -- Cost 200, cone AoE burn
    "TeslaTurret",         -- Cost 450, chain lightning
    "MissileTower",        -- Cost 500, splash
}

local function getOwnedTowers()
    local owned = {}
    local tmt = ReplicatedStorage:FindFirstChild("TowerModelTemplates")
    for k, v in pairs(LocalPlayer:GetAttributes()) do
        if type(v) == "number" and v > 0 then
            local tName = tostring(k):match("^TowerMax_(.+)$")
            if tName and not tName:find("^Pet_") then
                local tpl = tmt and tmt:FindFirstChild(tName)
                local eco = tpl and tpl:GetAttribute("EconomyTower") == true
                local cost = tpl and tonumber(tpl:GetAttribute("Cost")) or nil
                local rar = tpl and tostring(tpl:GetAttribute("Rarity") or "") or ""
                local disp = tpl and tostring(tpl:GetAttribute("DisplayName") or tName) or tName
                owned[tName] = {
                    name = tName,
                    display = disp,
                    maxOwned = v,
                    eco = eco,
                    cost = cost,
                    rarity = rar,
                    rarityScore = RARITY_RANK[rar] or 0,
                }
            end
        end
    end
    return owned
end

local function loadoutTypes()
    local s = attr("TowerLoadout")
    local out = {}
    if typeof(s) == "string" and s ~= "" then
        for name in string.gmatch(s, "[^,]+") do
            local trimmed = name:match("^%s*(.-)%s*$")
            if trimmed ~= "" and not trimmed:find("^Pet_") then out[#out + 1] = trimmed end
        end
    end
    if #out == 0 then
        out = { "FlamethrowerTurret", "CrossbowTower", "Farm", "MoneyMachine" }
    end
    return out
end

local function computeBestOwnedLoadout(preset)
    local owned = getOwnedTowers()
    local cap = math.max(1, tonumber(attr("LoadoutCapacity")) or 4)
    local picked, pickedSet = {}, {}

    local function addIfOwned(name)
        if #picked >= cap or pickedSet[name] or not owned[name] then return false end
        pickedSet[name] = true
        picked[#picked + 1] = name
        return true
    end

    -- Compare Epic heavy pair (Tesla vs Missile) using actual unlocked TowerMax_* level caps
    local heavyOrder = {}
    for _, n in ipairs(COMBAT_HEAVY_ORDER) do heavyOrder[#heavyOrder + 1] = n end
    if owned.TeslaTurret and owned.MissileTower then
        local tCap = owned.TeslaTurret.maxOwned or 6
        local mCap = owned.MissileTower.maxOwned or 6
        if tCap <= 6 and mCap >= 7 then
            local iT = table.find(heavyOrder, "TeslaTurret")
            local iM = table.find(heavyOrder, "MissileTower")
            if iT and iM and iT < iM then
                heavyOrder[iT], heavyOrder[iM] = heavyOrder[iM], heavyOrder[iT]
            end
        end
    end

    if preset == "ปั๊มเงินจัดเต็ม + กัน 1 ป้อม" then
        for _, n in ipairs(ECO_POWER_ORDER) do
            if #picked >= math.max(1, cap - 1) then break end
            addIfOwned(n)
        end
        for _, n in ipairs(heavyOrder) do
            if addIfOwned(n) then break end
        end
    elseif preset == "ปั๊มเงิน + AoE + บัฟ (ชนะโหมดยาก)" then
        -- With 4 slots in Solo Hard/Nightmare:
        -- 1 High-Cap Farm (VoidFarm / DivineBank / MiningCaveFarm 26) + 1 Affordable Wave-1/AoE DPS + 1 Heavy Long-Range DPS + 1 Buff (MilitaryBase)
        if cap >= 5 then
            addIfOwned("MoneyMachine")
        end
        for _, n in ipairs({ "VoidFarm", "DivineBank", "VaultFarm", "MiningCaveFarm" }) do
            if addIfOwned(n) then break end
        end
        -- Ensure at least 1 affordable Wave-1 AoE/DPS ($200 FlamethrowerTurret or Tesla/Crossbow) + 1 Heavy AoE/DPS
        for _, n in ipairs({ "FlamethrowerTurret", "TeslaTurret", "FireSpitterTurret", "ToxicTurret", "CrossbowTower" }) do
            if addIfOwned(n) then break end
        end
        for _, n in ipairs(heavyOrder) do
            if #picked >= math.max(3, cap - 1) then break end
            addIfOwned(n)
        end
        for _, n in ipairs(SUPPORT_BUFF_ORDER) do
            if addIfOwned(n) then break end
        end
        for _, n in ipairs(heavyOrder) do addIfOwned(n) end
        for _, n in ipairs(COMBAT_CHEAP_ORDER) do addIfOwned(n) end
    elseif preset == "ตีถูก & เคลียร์ไว (เน้นดาเมจ)" then
        addIfOwned("MoneyMachine")
        for _, n in ipairs(COMBAT_CHEAP_ORDER) do
            addIfOwned(n)
            if #picked >= math.max(2, math.floor(cap / 2) + 1) then break end
        end
        for _, n in ipairs(heavyOrder) do addIfOwned(n) end
    else
        -- Default: ดีที่สุดจากคลัง (ปั๊มเงิน+แรง+ถูก) — prioritize 1 High-Cap Farm + 2 AoE/Heavy DPS + 1 Support Buff
        if cap >= 5 then
            addIfOwned("MoneyMachine")
        end
        for _, n in ipairs({ "VoidFarm", "DivineBank", "VaultFarm", "MiningCaveFarm" }) do
            if addIfOwned(n) then break end
        end
        for _, n in ipairs({ "FlamethrowerTurret", "TeslaTurret", "FireSpitterTurret", "ToxicTurret", "CrossbowTower" }) do
            if addIfOwned(n) then break end
        end
        for _, n in ipairs(heavyOrder) do
            if #picked >= math.max(3, cap - 1) then break end
            addIfOwned(n)
        end
        for _, n in ipairs(SUPPORT_BUFF_ORDER) do
            if addIfOwned(n) then break end
        end
        addIfOwned("MoneyMachine")
        for _, n in ipairs(heavyOrder) do addIfOwned(n) end
        for _, n in ipairs(COMBAT_CHEAP_ORDER) do addIfOwned(n) end
    end

    -- Fallback: fill remaining slots from any remaining owned towers
    for name, _ in pairs(owned) do
        addIfOwned(name)
    end
    return picked
end

local function applyLoadoutViaRemote(targetList)
    if type(targetList) ~= "table" or #targetList == 0 then
        return false, "ไม่พบป้อมในคลัง"
    end
    local rem = ReplicatedStorage:FindFirstChild("Remotes")
    local setEq = rem and rem:FindFirstChild("SetEquipped")
    if not setEq then
        return false, "ไม่พบ Remotes.SetEquipped (ต้องกดในหน้า Lobby)"
    end

    local want = {}
    for _, name in ipairs(targetList) do want[name] = true end

    local cur = loadoutTypes()
    local curSet = {}
    for _, name in ipairs(cur) do curSet[name] = true end

    -- Unequip unneeded towers first so slots free up
    for _, name in ipairs(cur) do
        if not want[name] then
            local ok, res = pcall(function() return setEq:InvokeServer(name, false) end)
            if not ok then
                return false, "ถอด " .. name .. " ล้มเหลว: " .. tostring(res)
            end
            task.wait(0.1)
        end
    end

    -- Equip desired towers
    for _, name in ipairs(targetList) do
        if not curSet[name] then
            local ok, res = pcall(function() return setEq:InvokeServer(name, true) end)
            if not ok or (type(res) == "table" and res.ok == false) then
                local err = (type(res) == "table" and res.err) or tostring(res)
                return false, "ใส่ " .. name .. " ล้มเหลว: " .. tostring(err)
            end
            task.wait(0.1)
        end
    end

    return true, "จัดชุดแล้ว: " .. table.concat(targetList, ", ")
end

-- ---------------------------------------------------------------- game modules & Match systems
local TowerConfig
local TowerTargeting
local PlayAgainConfig
local ClanDoors
local DoorVisuals
local GameSpeed
local SpeedBoostConfig
local PvPConfig

local function tryLoadMatchModules()
    if not TowerConfig then
        local m = ReplicatedStorage:FindFirstChild("TowerConfig")
        if m and m:IsA("ModuleScript") then pcall(function() TowerConfig = require(m) end) end
    end
    if not TowerTargeting then
        local m = ReplicatedStorage:FindFirstChild("TowerTargeting")
        if m and m:IsA("ModuleScript") then pcall(function() TowerTargeting = require(m) end) end
    end
    if not PlayAgainConfig then
        local m = ReplicatedStorage:FindFirstChild("PlayAgainConfig")
        if m and m:IsA("ModuleScript") then pcall(function() PlayAgainConfig = require(m) end) end
    end
    if not ClanDoors then
        local m = ReplicatedStorage:FindFirstChild("ClanDoors")
        if m and m:IsA("ModuleScript") then pcall(function() ClanDoors = require(m) end) end
    end
    if not DoorVisuals then
        local m = ReplicatedStorage:FindFirstChild("DoorVisuals")
        if m and m:IsA("ModuleScript") then pcall(function() DoorVisuals = require(m) end) end
    end
    if not GameSpeed then
        local m = ReplicatedStorage:FindFirstChild("GameSpeed")
        if m and m:IsA("ModuleScript") then pcall(function() GameSpeed = require(m) end) end
    end
    if not SpeedBoostConfig then
        local m = ReplicatedStorage:FindFirstChild("SpeedBoostConfig")
        if m and m:IsA("ModuleScript") then pcall(function() SpeedBoostConfig = require(m) end) end
    end
    if not PvPConfig then
        local m = ReplicatedStorage:FindFirstChild("PvPConfig")
        if m and m:IsA("ModuleScript") then pcall(function() PvPConfig = require(m) end) end
    end
end
task.spawn(tryLoadMatchModules)

local function isPvPMode()
    return workspace:GetAttribute("ResolvedGameMode") == "PvP"
        or workspace:GetAttribute("ActiveGameMode") == "PvP"
        or workspace:GetAttribute("PvPPhase") ~= nil
end

local function pvpRemote(name)
    local pr = ReplicatedStorage:FindFirstChild("PvPRemotes")
    return pr and pr:FindFirstChild(name)
end

local function tdRemote(name)
    local tdr = ReplicatedStorage:FindFirstChild("TowerDefenseRemotes")
    return tdr and tdr:FindFirstChild(name)
end

local function getCurrentSpeedMultiplier()
    tryLoadMatchModules()
    if GameSpeed and type(GameSpeed.Multiplier) == "function" then
        local ok, m = pcall(GameSpeed.Multiplier, LocalPlayer)
        if ok and type(m) == "number" and m >= 1 then return m end
    end
    return 1
end

local function canUseSpeed(mult)
    tryLoadMatchModules()
    if mult == 1 then return true end
    if mult == 2 then
        if SpeedBoostConfig and type(SpeedBoostConfig.Has2x) == "function" then
            local ok, res = pcall(SpeedBoostConfig.Has2x, LocalPlayer)
            if ok then return res == true end
        end
        return true
    elseif mult == 3 then
        if SpeedBoostConfig and type(SpeedBoostConfig.Has3x) == "function" then
            local ok, res = pcall(SpeedBoostConfig.Has3x, LocalPlayer)
            if ok then return res == true end
        end
        return attr("OwnsVIPPass") == true
    elseif mult == 4 then
        if SpeedBoostConfig and type(SpeedBoostConfig.IsUnlimitedQuad) == "function" then
            local ok, res = pcall(SpeedBoostConfig.IsUnlimitedQuad, LocalPlayer.UserId)
            if ok and res == true then return true end
        end
        local bankedAttr = (SpeedBoostConfig and SpeedBoostConfig.QuadBankedAttribute) or "Speed4Seconds"
        local banked = tonumber(attr(bankedAttr)) or 0
        if banked > 0 then return true end
        if getCurrentSpeedMultiplier() == 4 then return true end
        return false
    end
    return false
end

local function resolveDesiredSpeed(targetLabel)
    local s = tostring(targetLabel or "2x")
    if string.find(s, "4x->3x->2x", 1, true) then
        if canUseSpeed(4) then return 4, true end
        if canUseSpeed(3) then return 3, true end
        return 2, canUseSpeed(2)
    elseif string.sub(s, 1, 2) == "4x" then
        if canUseSpeed(4) then return 4, true end
        if canUseSpeed(3) then return 3, true end
        return 2, canUseSpeed(2)
    elseif string.sub(s, 1, 2) == "3x" then
        if canUseSpeed(3) then return 3, true end
        return 2, canUseSpeed(2)
    elseif string.sub(s, 1, 2) == "2x" then
        return 2, canUseSpeed(2)
    elseif string.sub(s, 1, 2) == "1x" then
        return 1, true
    end
    return 2, canUseSpeed(2)
end

local function buildSpeedStatusText()
    tryLoadMatchModules()
    local cur = getCurrentSpeedMultiplier()
    local has2 = canUseSpeed(2)
    local has3 = canUseSpeed(3)
    local bankedAttr = (SpeedBoostConfig and SpeedBoostConfig.QuadBankedAttribute) or "Speed4Seconds"
    local sec4 = math.max(0, math.floor(tonumber(attr(bankedAttr)) or 0))
    local has4 = canUseSpeed(4)
    local rem = 0
    if GameSpeed and type(GameSpeed.SecondsRemaining) == "function" then
        local okR, vR = pcall(GameSpeed.SecondsRemaining, LocalPlayer)
        if okR and type(vR) == "number" then rem = math.max(0, math.floor(vR)) end
    end
    local s4Text = has4 and (sec4 > 0 and ("พร้อม (" .. sec4 .. "s)") or "พร้อม (Unlimited/Active)") or "0s (ต้องซื้อเวลา 4x)"
    return string.format(
        "ความเร็วปัจจุบัน: %dx%s\nสิทธิ์ที่มี — 2x: %s | 3x: %s | 4x: %s",
        cur,
        (cur == 4 and rem > 0) and (" (เหลือ " .. rem .. "s)") or "",
        has2 and "ฟรี (พร้อมใช้)" or "ไม่พร้อม",
        has3 and "VIP (พร้อมใช้)" or "ต้องมี VIP Pass",
        s4Text
    )
end

local function applySpeedMultiplier(targetMult, isToggleAction)
    tryLoadMatchModules()
    if workspace:GetAttribute("ResolvedGameMode") == "PvP" then
        return false, "โหมด PvP ไม่รองรับปรับความเร็ว"
    end
    local remoteName = (SpeedBoostConfig and SpeedBoostConfig.ToggleRemoteName) or "SpeedToggle"
    local rf = tdRemote(remoteName)
    if not rf then
        return false, "ไม่พบ Remote " .. tostring(remoteName)
    end
    local cur = getCurrentSpeedMultiplier()
    if targetMult == 1 then
        if cur <= 1 then return false, "อยู่ที่ 1x อยู่แล้ว" end
        rf:FireServer(cur)
        return true, "ส่งคำสั่งรีเซ็ตความเร็วกลับ 1x แล้ว"
    end
    if cur == targetMult then
        if isToggleAction then
            rf:FireServer(targetMult)
            return true, string.format("สลับปิด %dx -> 1x แล้ว", targetMult)
        end
        return false, string.format("อยู่ที่ %dx อยู่แล้ว", targetMult)
    end
    if not canUseSpeed(targetMult) then
        if targetMult == 3 then
            return false, "3x ต้องมี VIP Pass ก่อน (เซิร์ฟเวอร์ตรวจสอบ)"
        elseif targetMult == 4 then
            return false, "4x ต้องมีเวลา Speed4Seconds (ตอนนี้เหลือ 0s)"
        end
        return false, "ยังไม่ปลดล็อก " .. tostring(targetMult) .. "x"
    end
    rf:FireServer(targetMult)
    return true, string.format("ส่งคำสั่งเปลี่ยนความเร็วเป็น %dx แล้ว", targetMult)
end

local function housesFolder()
    local map = workspace:FindFirstChild("GameMap")
    return map and map:FindFirstChild("Houses")
end

local function myHouse()
    local houses = housesFolder()
    if not houses then return nil end

    local name = attr("ClaimedHouseName")
    if typeof(name) == "string" and name ~= "" then
        local h = houses:FindFirstChild(name)
        if h and (h:GetAttribute("OwnerUserId") == LocalPlayer.UserId or (TowerConfig and TowerConfig.IsHouseMember and TowerConfig.IsHouseMember(h, LocalPlayer.UserId))) then
            return h
        end
    end

    local teamName = attr("TeamHouseName")
    if typeof(teamName) == "string" and teamName ~= "" then
        local h = houses:FindFirstChild(teamName)
        if h and TowerConfig and TowerConfig.IsHouseMember and TowerConfig.IsHouseMember(h, LocalPlayer.UserId) then
            return h
        end
    end

    if isPvPMode() then
        local myTeam = tonumber(attr("PvPTeam"))
        for _, h in ipairs(houses:GetChildren()) do
            if h:GetAttribute("OwnerUserId") == LocalPlayer.UserId
                or (myTeam and tonumber(h:GetAttribute("PvPSide")) == myTeam and (tonumber(h:GetAttribute("OwnerUserId")) or 0) > 0) then
                return h
            end
        end
    end

    return nil
end

local function getDoorCount(house)
    if not house then return 1 end
    if ClanDoors and type(ClanDoors.GetDoorCount) == "function" then
        local ok, n = pcall(ClanDoors.GetDoorCount, house)
        if ok and type(n) == "number" and n >= 1 then return math.floor(n) end
    end
    local attrN = house:GetAttribute("DoorFolderCount")
    if type(attrN) == "number" and attrN >= 1 then return math.floor(attrN) end
    return house:FindFirstChild("Doors2") and 2 or 1
end

local function isMultiDoorHouse(house)
    if not house then return false end
    if ClanDoors and type(ClanDoors.IsMultiDoorHouse) == "function" then
        local ok, res = pcall(ClanDoors.IsMultiDoorHouse, house)
        if ok then return res == true end
    end
    return getDoorCount(house) > 1
end

local function getDoorsInfo(house)
    if not house then return {} end
    local count = getDoorCount(house)
    local multi = isMultiDoorHouse(house) or count > 1
    local out = {}

    for i = 1, count do
        local suffix = multi and tostring(i) or ""
        local lvl = tonumber(house:GetAttribute("DoorLevel" .. suffix)) or tonumber(house:GetAttribute("DoorLevel")) or 1
        local broken = house:GetAttribute("DoorBroken" .. suffix) == true
        if not multi and house:GetAttribute("DoorBroken") == true then broken = true end

        local hp = house:GetAttribute("DoorHP" .. suffix)
        if hp == nil then hp = house:GetAttribute("DoorHP") end
        hp = type(hp) == "number" and hp or 0

        local maxHp = house:GetAttribute("DoorMaxHP" .. suffix)
        if maxHp == nil then maxHp = house:GetAttribute("DoorMaxHP") end
        if type(maxHp) ~= "number" or maxHp <= 0 then
            if TowerConfig and type(TowerConfig.GetDoorMaxHP) == "function" then
                local okM, mx = pcall(TowerConfig.GetDoorMaxHP, lvl, house)
                if okM and type(mx) == "number" then maxHp = mx end
            end
        end
        maxHp = (type(maxHp) == "number" and maxHp > 0) and maxHp or 1
        local pct = math.clamp((hp / maxHp) * 100, 0, 100)

        local part = nil
        if ClanDoors and count > 1 and type(ClanDoors.GetActiveDoorPart) == "function" then
            local okP, p = pcall(ClanDoors.GetActiveDoorPart, house, i)
            if okP and typeof(p) == "Instance" then part = p end
        elseif DoorVisuals and type(DoorVisuals.GetActiveDoorPart) == "function" then
            local okP, p = pcall(DoorVisuals.GetActiveDoorPart, house)
            if okP and typeof(p) == "Instance" then part = p end
        end

        out[#out + 1] = {
            index = i,
            fireArg = multi and i or nil,
            level = math.max(1, math.floor(lvl)),
            hp = hp,
            maxHp = maxHp,
            pct = pct,
            broken = broken,
            part = part,
        }
    end
    return out
end

local function pickLowestDoor(house)
    local best = nil
    for _, d in ipairs(getDoorsInfo(house)) do
        if not d.broken then
            if not best or d.level < best.level or (d.level == best.level and d.pct < best.pct) then
                best = d
            end
        end
    end
    return best
end

local function pickMostDamagedDoor(house)
    local best = nil
    for _, d in ipairs(getDoorsInfo(house)) do
        if not d.broken then
            if not best or d.pct < best.pct or (d.pct == best.pct and d.level < best.level) then
                best = d
            end
        end
    end
    return best
end

local function worstDoorPct(house)
    local worst = nil
    for _, d in ipairs(getDoorsInfo(house)) do
        if not d.broken and d.maxHp > 0 then
            if worst == nil or d.pct < worst then worst = d.pct end
        end
    end
    return worst
end

local function cashValue()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    return ls and ls:FindFirstChild("Cash")
end

local function isIncome(ttype)
    if TowerConfig and type(TowerConfig.IsEconomyTower) == "function" then
        local ok, res = pcall(TowerConfig.IsEconomyTower, ttype)
        if ok then return res == true end
    end
    return type(ttype) == "string" and (
        string.find(ttype, "Farm", 1, true) ~= nil
        or string.find(ttype, "MoneyMachine", 1, true) ~= nil
        or string.find(ttype, "Bank", 1, true) ~= nil
    )
end

local function isSupport(ttype)
    if TowerConfig and type(TowerConfig.IsSupportTower) == "function" then
        local ok, res = pcall(TowerConfig.IsSupportTower, ttype)
        if ok and res == true then return true end
    end
    return ttype == "MilitaryBase" or ttype == "ProtectorTower" or ttype == "MedicalBase"
end

local function isCombat(ttype)
    if isIncome(ttype) or isSupport(ttype) then return false end
    if TowerConfig and type(TowerConfig.IsCombatTower) == "function" then
        local ok, res = pcall(TowerConfig.IsCombatTower, ttype)
        if ok then return res == true end
    end
    return true
end

-- Forward ref to ensure Window stays visible cleanly after base teleports
local ensureWindowVisible = function() end

-- ---------------------------------------------------------------- MATCH-ONLY SYSTEMS
local ddBase, paraOverview, paraTelemetry, paraSpeedStatus, paraChestInfo, paraPetInfo, paraPvPStatus, paraStrategyPlan, getChestInfoText, getPetInfoText, getPvPStatusText, getStrategyPlanText, pvpTriggerDraftNow
local PVP_BAN_CHOICES = {
    "GolemForge", "DivineBank", "MortarMachine", "CrusherTower", "WorldEnderTurret",
    "RailgunTurret", "SamuraiTower", "VoidFarm", "LavaLauncher", "MilitaryBase",
    "ToxicTurret", "IceTurret", "FireSpitterTurret", "BallistaTower", "VaultFarm",
    "Pet_Horse", "Pet_Dragon", "Pet_Bunny",
}
local function parseCsvList(str)
    local arr, set = {}, {}
    if type(str) == "table" then
        for k, v in pairs(str) do
            local val = (type(k) == "number" and type(v) == "string") and v or (type(k) == "string" and v == true and k or nil)
            if val and not set[val] then set[val] = true arr[#arr + 1] = val end
        end
        return arr, set
    end
    for tok in string.gmatch(tostring(str or ""), "[^,]+") do
        local t = tok:match("^%s*(.-)%s*$")
        if t ~= "" and not set[t] then
            set[t] = true
            arr[#arr + 1] = t
        end
    end
    return arr, set
end
local function setParaSafe(para, txt)
    if not (para and type(para.SetContent) == "function") then return end
    task.spawn(function()
        pcall(function() para:SetContent(txt) end)
    end)
end
local baseLabelToName = {}

local function getHouseInteriorInfo(house)
    tryLoadMatchModules()
    if TowerConfig and type(TowerConfig.GetHouseFloorParts) == "function" then
        local okP, floors = pcall(TowerConfig.GetHouseFloorParts, house, true)
        if okP and type(floors) == "table" and #floors > 0 then
            local vipFolder = house:FindFirstChild("VIP")
            local bestFloor = nil
            local bestArea = -1
            local totalArea = 0
            for _, p in ipairs(floors) do
                if p:IsA("BasePart") then
                    local inVip = vipFolder and p:IsDescendantOf(vipFolder)
                    if not inVip or attr("OwnsVIPPass") == true then
                        local area = p.Size.X * p.Size.Z
                        totalArea += area
                        if area > bestArea then
                            bestArea = area
                            bestFloor = p
                        end
                    end
                end
            end
            bestFloor = bestFloor or floors[1]
            if bestFloor and bestFloor:IsA("BasePart") then
                return bestFloor.CFrame * CFrame.new(0, bestFloor.Size.Y * 0.5 + 3.5, 0), math.floor(totalArea)
            end
        end
    end
    return house:GetPivot() + Vector3.new(0, 4, 0), 0
end

local function getHouseInteriorCFrame(house)
    local cf = getHouseInteriorInfo(house)
    return cf
end

local function scanBases()
    table.clear(baseLabelToName)
    local houses = housesFolder()
    if not houses then return { "(ไม่พบ Houses ในแผนที่)" }, {} end

    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local curPos = hrp and hrp.Position
    local mine = myHouse()

    local items = {}
    for _, h in ipairs(houses:GetChildren()) do
        if h:IsA("Model") or h:IsA("Folder") then
            local doors = getDoorCount(h)
            local ownerId = tonumber(h:GetAttribute("OwnerUserId")) or 0
            local claimed = h:GetAttribute("IsClaimed") == true or ownerId > 0
            local isMine = (mine == h) or (TowerConfig and TowerConfig.IsHouseMember and TowerConfig.IsHouseMember(h, LocalPlayer.UserId))
            local statusStr = isMine and "ฐานของเรา" or (claimed and "มีคนแล้ว" or "ว่าง")
            local cf, area = getHouseInteriorInfo(h)
            local dist = curPos and math.floor((cf.Position - curPos).Magnitude) or 9999
            local label = string.format("%s | %d ประตู | พื้นที่ %d | %s (%dm)", h.Name, doors, area, statusStr, dist)
            baseLabelToName[label] = h.Name
            items[#items + 1] = {
                label = label,
                name = h.Name,
                house = h,
                doors = doors,
                area = area,
                claimed = claimed,
                isMine = isMine,
                dist = dist,
                cf = cf,
            }
        end
    end

    table.sort(items, function(a, b)
        if a.claimed ~= b.claimed then return not a.claimed end
        if a.doors ~= b.doors then return a.doors < b.doors end
        if a.area ~= b.area then return a.area > b.area end
        return a.dist < b.dist
    end)

    local labels = {}
    for _, it in ipairs(items) do labels[#labels + 1] = it.label end
    if #labels == 0 then labels[1] = "(ไม่พบฐานในแผนที่)" end
    return labels, items
end

local function pickBestBaseItem(items, pref)
    if type(items) ~= "table" or #items == 0 then return nil end
    if pref == "ตามที่เลือกใน Dropdown" and State.SelectedBase then
        local targetName = baseLabelToName[State.SelectedBase] or State.SelectedBase
        for _, it in ipairs(items) do
            if it.name == targetName and not it.claimed then return it end
        end
    end

    local free = {}
    for _, it in ipairs(items) do
        if not it.claimed then free[#free + 1] = it end
    end
    if #free == 0 then return nil end

    if pref == "1 ประตู + พื้นที่กว้างสุด (ชนะง่าย)" or pref == "ฐาน 1 ประตู (ว่าง)" then
        table.sort(free, function(a, b)
            local a1, b1 = a.doors <= 1, b.doors <= 1
            if a1 ~= b1 then return a1 end
            if a.area ~= b.area then return a.area > b.area end
            return a.dist < b.dist
        end)
        return free[1]
    elseif pref == "ฐานหลายประตู (ว่าง)" then
        table.sort(free, function(a, b)
            local am, bm = a.doors > 1, b.doors > 1
            if am ~= bm then return am end
            if a.area ~= b.area then return a.area > b.area end
            return a.dist < b.dist
        end)
        return free[1]
    end

    -- ฐานว่างใกล้สุด
    table.sort(free, function(a, b) return a.dist < b.dist end)
    return free[1]
end

local function teleportToBaseName(houseName)
    if not houseName or houseName == "" then return false, "กรุณาเลือกฐานก่อน" end
    local houses = housesFolder()
    local h = houses and houses:FindFirstChild(houseName)
    if not h then return false, "ไม่พบฐาน: " .. tostring(houseName) end
    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false, "ไม่พบตัวละคร (HumanoidRootPart)" end
    hrp.CFrame = getHouseInteriorCFrame(h)
    task.defer(ensureWindowVisible)
    local ownerId = tonumber(h:GetAttribute("OwnerUserId")) or 0
    local claimed = h:GetAttribute("IsClaimed") == true or ownerId > 0
    if claimed and not (TowerConfig and TowerConfig.IsHouseMember and TowerConfig.IsHouseMember(h, LocalPlayer.UserId)) then
        return true, "วาร์ปไปหน้า/ในฐาน " .. h.Name .. " (ฐานมีเจ้าของแล้ว กดขอร่วมทีมได้)"
    end
    return true, "วาร์ปเข้าฐาน " .. h.Name .. " สำเร็จ"
end

if IS_MATCH then
    -- Monster ESP
    local ESPFolder = Instance.new("Folder")
    ESPFolder.Name = "TDHub_ESP"
    ESPFolder.Parent = hui()
    Hub.cleanups[#Hub.cleanups + 1] = function() pcall(function() ESPFolder:Destroy() end) end

    local espMap = {}
    local function espClear()
        for m, h in pairs(espMap) do
            pcall(function() h:Destroy() end)
            espMap[m] = nil
        end
    end
    Hub.cleanups[#Hub.cleanups + 1] = espClear

    local lastESP = 0
    track(RunService.Heartbeat:Connect(function()
        if not Hub.alive then return end
        if not State.MonsterESP then
            if next(espMap) then espClear() end
            return
        end
        local now = os.clock()
        if now - lastESP < 0.4 then return end
        lastESP = now
        local root = workspace:FindFirstChild("MonsterSystem")
        if not root then
            if next(espMap) then espClear() end
            return
        end
        local alive, count = {}, 0
        for _, m in ipairs(root:GetChildren()) do
            if m:IsA("Model") then
                alive[m] = true
                count += 1
                if not espMap[m] and count <= State.ESPMax then
                    local h = Instance.new("Highlight")
                    h.Name = "TD_ESP"
                    h.Adornee = m
                    h.FillColor = Color3.fromRGB(255, 70, 70)
                    h.FillTransparency = 0.55
                    h.OutlineColor = Color3.fromRGB(255, 255, 255)
                    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    h.Parent = ESPFolder
                    espMap[m] = h
                end
            end
        end
        for m, h in pairs(espMap) do
            if not alive[m] or not m.Parent then
                pcall(function() h:Destroy() end)
                espMap[m] = nil
            end
        end
    end))

    -- Auto Claim Base loop
    local lastClaimAttempt = 0
    track(RunService.Heartbeat:Connect(function()
        if not (Hub.alive and State.AutoClaimBase) then return end
        if isPvPMode() or workspace:GetAttribute("HouseSelectionClosed") == true then return end
        if myHouse() then return end
        local now = os.clock()
        if now - lastClaimAttempt < 3.5 then return end

        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        tryLoadMatchModules()
        local _, items = scanBases()
        local chosen = pickBestBaseItem(items, State.BasePreference)

        if chosen then
            lastClaimAttempt = now
            hrp.CFrame = chosen.cf
            task.defer(ensureWindowVisible)
        end
    end))

    -- Shared debounces & smart placement helpers
    local recentUp = setmetatable({}, { __mode = "k" })
    local recentCell = {}
    local recentBank = setmetatable({}, { __mode = "k" })
    local recentForge = setmetatable({}, { __mode = "k" })
    local lastDoorUp = { level = nil, doorIdx = nil, t = 0 }
    local nextRepairOk, free2xGuard = 0, 0
    local playAgainVoted = false
    local lastSpeedFire = 0

    local function getNextDoorUpgradeCost(house, door)
        local worst = worstDoorPct(house)
        door = door or ((worst and worst < 62) and pickMostDamagedDoor(house) or pickLowestDoor(house))
        if not door then return nil, nil end
        local okC, cost = false, nil
        if isPvPMode() then
            if PvPConfig and type(PvPConfig.DoorUpgradeCost) == "function" then
                okC, cost = pcall(PvPConfig.DoorUpgradeCost, door.level)
            end
            if not (okC and type(cost) == "number") then
                okC, cost = true, 150 * math.max(1, math.floor(tonumber(door.level) or 1))
            end
        elseif TowerConfig and type(TowerConfig.GetDoorUpgradeCost) == "function" then
            okC, cost = pcall(TowerConfig.GetDoorUpgradeCost, door.level, house)
        end
        if okC and type(cost) == "number" then
            return cost, door
        end
        return nil, door
    end

    local function fireRepairIfReady(house, belowPct)
        local worst = worstDoorPct(house)
        if worst == nil or worst >= belowPct then return false end
        local ready = attr("DoorRepairReadyAt")
        local srv = workspace:GetServerTimeNow()
        local rf = tdRemote("GatePatch")
        if rf and srv >= (type(ready) == "number" and ready or 0) and srv >= nextRepairOk then
            nextRepairOk = srv + 0.35
            rf:FireServer()
            return true
        end
        return false
    end

    local function fireDoorUpgrade(house, cash, reserve, targetDoor)
        local rf = tdRemote("GateReinforce")
        if not (rf and cash) then return false end
        local cost, door = getNextDoorUpgradeCost(house, targetDoor)
        if not (door and type(cost) == "number") then return false end
        if cash.Value - cost >= (tonumber(reserve) or 0) then
            local now = os.clock()
            if not (lastDoorUp.level == door.level and lastDoorUp.doorIdx == door.index and now - lastDoorUp.t < 0.45) then
                lastDoorUp.level, lastDoorUp.doorIdx, lastDoorUp.t = door.level, door.index, now
                rf:FireServer(door.fireArg)
                return true
            end
        end
        return false
    end

    -- Fast 0.12s Door Guardian: triggers GatePatch at 99.9% HP the instant cooldown ends,
    -- and emergency-upgrades the most damaged door (GateReinforce burst HP) if a door drops low while repair is on cooldown
    local lastFastDoorGuard = 0
    track(RunService.Heartbeat:Connect(function()
        if not (Hub.alive and (State.AutoWin or State.AutoRepair or State.AutoDoorUp)) then return end
        local now = os.clock()
        if now - lastFastDoorGuard < 0.12 then return end
        lastFastDoorGuard = now
        local house = myHouse()
        if not house then return end
        local repairThreshold = State.AutoWin and 99.9 or State.RepairBelow
        if State.AutoWin or State.AutoRepair then
            fireRepairIfReady(house, repairThreshold)
        end
        local worst = worstDoorPct(house)
        if worst and (State.AutoWin or State.AutoDoorUp) then
            local ready = tonumber(attr("DoorRepairReadyAt")) or 0
            local activeUntil = tonumber(attr("DoorRepairActiveUntil")) or 0
            local srv = workspace:GetServerTimeNow()
            local repairOnCooldown = (srv < ready) and (srv >= activeUntil)
            -- Even 1 broken door loses the match -> upgrade endangered door promptly if HP drops critically
            if worst < 44 or (repairOnCooldown and worst < 60) then
                local cash = cashValue()
                if cash then
                    fireDoorUpgrade(house, cash, 0, pickMostDamagedDoor(house))
                end
            end
        end
    end))

    local function collectDoorPositions(house)
        local pts = {}
        for _, d in ipairs(getDoorsInfo(house)) do
            if d.part and d.part:IsA("BasePart") then
                pts[#pts + 1] = { index = d.index, broken = d.broken, pos = d.part.Position }
            end
        end
        if #pts == 0 then
            pts[1] = { index = 1, broken = false, pos = house:GetPivot().Position }
        end
        return pts
    end

    local function freeCellsDetailed(house)
        local okO, origin = pcall(TowerConfig.GetHouseGridOrigin, house)
        local okP, floors = pcall(TowerConfig.GetHouseFloorParts, house, true)
        if not (okO and okP and type(floors) == "table") then return {}, {} end

        local vipParts = {}
        local vip = house:FindFirstChild("VIP")
        if vip and attr("OwnsVIPPass") ~= true then
            for _, d in ipairs(vip:GetDescendants()) do
                if d:IsA("BasePart") then vipParts[#vipParts + 1] = d end
            end
        end

        local used = {}
        local placed = workspace:FindFirstChild("PlacedTowers")
        if placed then
            for _, tw in ipairs(placed:GetChildren()) do
                local k = tw:GetAttribute("GridKey")
                if k ~= nil then used[k] = true end
            end
        end

        local doors = collectDoorPositions(house)
        local out = {}
        for cx = -1, 30 do
            for cz = -1, 30 do
                local okW, w = pcall(TowerConfig.CellToWorld, cx, cz, 0, origin)
                if okW and typeof(w) == "Vector3" then
                    local onFloor = false
                    for _, p in ipairs(floors) do
                        local lp = p.CFrame:PointToObjectSpace(Vector3.new(w.X, p.Position.Y, w.Z))
                        if math.abs(lp.X) <= p.Size.X / 2 + 0.15 and math.abs(lp.Z) <= p.Size.Z / 2 + 0.15 then
                            onFloor = true
                            break
                        end
                    end
                    if onFloor then
                        local inVip = false
                        for _, p in ipairs(vipParts) do
                            local lp = p.CFrame:PointToObjectSpace(Vector3.new(w.X, p.Position.Y, w.Z))
                            if math.abs(lp.X) <= p.Size.X / 2 + 0.15 and math.abs(lp.Z) <= p.Size.Z / 2 + 0.15 then
                                inVip = true
                                break
                            end
                        end
                        local key = TowerConfig.HouseCellToKey(house.Name, cx, cz)
                        if not inVip and not used[key] then
                            local minD, distByDoor = math.huge, {}
                            for _, dp in ipairs(doors) do
                                local dXZ = Vector2.new(w.X - dp.pos.X, w.Z - dp.pos.Z).Magnitude
                                distByDoor[dp.index] = dXZ
                                if not dp.broken and dXZ < minD then minD = dXZ end
                            end
                            if minD == math.huge then
                                for _, dXZ in pairs(distByDoor) do
                                    if dXZ < minD then minD = dXZ end
                                end
                            end
                            out[#out + 1] = {
                                cx = cx,
                                cz = cz,
                                key = key,
                                world = w,
                                minDoorDist = minD,
                                distByDoor = distByDoor,
                            }
                        end
                    end
                end
            end
        end
        return out, doors
    end

    local function pickSmartCell(house, typeName, placedTowers)
        local now = os.clock()
        local cells, doors = freeCellsDetailed(house)
        if #cells == 0 then return nil, 0 end

        local combat = isCombat(typeName)
        local isHealer = (typeName == "MedicalBase") or (TowerConfig.IsHealerTower and TowerConfig.IsHealerTower(typeName))
        local support = isSupport(typeName) and not isHealer
        local isAura = isSupport(typeName)
            or (TowerConfig.IsProtectorTower and TowerConfig.IsProtectorTower(typeName))
            or (TowerConfig.IsAuraTower and TowerConfig.IsAuraTower(typeName))

        if support and #placedTowers > 0 then
            local capS = math.max(1, math.min(4, tonumber(attr("TowerMax_" .. typeName)) or 2))
            local okBR1, br1 = pcall(TowerConfig.GetTowerRange, typeName, 1)
            local okBR, br = pcall(TowerConfig.GetTowerRange, typeName, capS)
            local buffRad1 = (okBR1 and type(br1) == "number" and br1 >= 8) and br1 or 15
            local buffRad = (okBR and type(br) == "number" and br >= 12) and br or 25
            local function scoreSupportCell(c)
                local sc = 0
                local hitsAny = false
                for _, t in ipairs(placedTowers) do
                    local tt = t:GetAttribute("TowerType")
                    local p = t:GetPivot().Position
                    local dist = Vector2.new(c.world.X - p.X, c.world.Z - p.Z).Magnitude
                    if isCombat(tt) then
                        if dist <= buffRad then
                            hitsAny = true
                            local okC, tc = pcall(TowerConfig.GetPlaceCost, tt)
                            local tierW = ((okC and type(tc) == "number" and tc >= 450) and 3) or 1.5
                            local unbuffedMult = ((tonumber(t:GetAttribute("DamageBuff")) or 0) <= 0) and 2.5 or 1.0
                            local immediateBonus = (dist <= buffRad1) and 1.4 or 1.0
                            sc += tierW * unbuffedMult * immediateBonus
                        end
                    elseif tt == typeName then
                        if dist <= buffRad1 * 0.85 then sc -= 8 end
                    end
                end
                return sc, hitsAny
            end
            table.sort(cells, function(a, b)
                local sa = scoreSupportCell(a)
                local sb = scoreSupportCell(b)
                if math.abs(sa - sb) > 0.05 then return sa > sb end
                return a.minDoorDist < b.minDoorDist
            end)
            -- Don't waste an expensive narrow-range MilitaryBase on a far cell that buffs zero combat towers
            local bestSc, bestHits = scoreSupportCell(cells[1])
            if not bestHits or bestSc <= 0 then
                return nil, #cells
            end
        elseif combat or isAura then
            local cov = {}
            local buffs = {}
            for _, dp in ipairs(doors) do cov[dp.index] = 0 end
            for _, t in ipairs(placedTowers) do
                local tt = t:GetAttribute("TowerType")
                if isCombat(tt) then
                    local pos = t:GetPivot().Position
                    local bestIdx, bestDist = nil, math.huge
                    for _, dp in ipairs(doors) do
                        if not dp.broken then
                            local d = Vector2.new(pos.X - dp.pos.X, pos.Z - dp.pos.Z).Magnitude
                            if d < bestDist then bestDist = d bestIdx = dp.index end
                        end
                    end
                    if bestIdx then cov[bestIdx] = (cov[bestIdx] or 0) + 1 end
                elseif isSupport(tt) and tt ~= "MedicalBase" then
                    local okB, bRad = pcall(TowerConfig.GetTowerRange, tt, t:GetAttribute("Level") or 1)
                    buffs[#buffs + 1] = { pos = t:GetPivot().Position, rad = (okB and type(bRad) == "number" and bRad >= 10) and bRad or 18 }
                end
            end

            local targetDoorIdx, lowestCov = doors[1].index, math.huge
            for _, dp in ipairs(doors) do
                if not dp.broken and (cov[dp.index] or 0) < lowestCov then
                    lowestCov = cov[dp.index] or 0
                    targetDoorIdx = dp.index
                end
            end

            local okR, rng = pcall(TowerConfig.GetTowerRange, typeName, 1)
            rng = (okR and type(rng) == "number" and rng > 0) and rng or 24
            local ownedCapR = tonumber(attr("TowerMax_" .. typeName)) or 6
            local okRM, rngM = pcall(TowerConfig.GetTowerRange, typeName, ownedCapR)
            local rngMax = (okRM and type(rngM) == "number" and rngM >= rng) and rngM or rng
            local isLongRange = rng >= 36

            local function inBuffAura(worldPos)
                for _, bf in ipairs(buffs) do
                    if Vector2.new(worldPos.X - bf.pos.X, worldPos.Z - bf.pos.Z).Magnitude <= bf.rad then return true end
                end
                return false
            end
            local function hitsAllDoors(c)
                if #doors <= 1 then return c.minDoorDist <= rng * 0.9 end
                for _, dp in ipairs(doors) do
                    if not dp.broken and (c.distByDoor[dp.index] or math.huge) > rng * 0.92 then return false end
                end
                return true
            end

            table.sort(cells, function(a, b)
                local da = a.distByDoor[targetDoorIdx] or a.minDoorDist
                local db = b.distByDoor[targetDoorIdx] or b.minDoorDist
                local ina, inb = da <= rng * 0.9, db <= rng * 0.9
                if ina ~= inb then return ina end
                if isLongRange and #doors > 1 then
                    local aa, ab = hitsAllDoors(a), hitsAllDoors(b)
                    if aa ~= ab then return aa end
                end
                if isLongRange then
                    local ma, mb = (a.minDoorDist >= 16 and da <= rng * 0.85), (b.minDoorDist >= 16 and db <= rng * 0.85)
                    if ma ~= mb then return ma end
                end
                if #buffs > 0 then
                    local ba, bb = inBuffAura(a.world), inBuffAura(b.world)
                    if ba ~= bb then return ba end
                end
                return da < db
            end)
            -- Don't place a narrow-range combat tower in a far back cell that can't even reach a door at max level
            if combat and not isLongRange and cells[1] and cells[1].minDoorDist > rngMax * 0.96 then
                return nil, #cells
            end
        else
            table.sort(cells, function(a, b)
                return a.minDoorDist > b.minDoorDist
            end)
        end

        for _, c in ipairs(cells) do
            if now - (recentCell[c.key] or 0) > 3.5 then
                return c, #cells
            end
        end
        return nil, #cells
    end

    local function ensureNearWorldPos(pos, yieldAfterMove)
        if not State.AutoMoveToCell or typeof(pos) ~= "Vector3" then return false end
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return false end
        local maxD = (TowerConfig and type(TowerConfig.MaxPlaceDistance) == "number" and TowerConfig.MaxPlaceDistance) or 30
        local safeLimit = math.min(18, math.max(10, maxD - 10))
        if (hrp.Position - pos).Magnitude > safeLimit then
            hrp.CFrame = CFrame.new(pos.X, pos.Y + 3.2, pos.Z) * hrp.CFrame.Rotation
            if yieldAfterMove then
                task.wait(0.08)
            end
            return true
        end
        return false
    end

    local function drainAndForgeOwned(house, minBankPct)
        local placed = workspace:FindFirstChild("PlacedTowers")
        if not (house and placed and TowerConfig) then return end
        local now = os.clock()
        local vaultRf = tdRemote("VaultDrain")
        local forgeRf = tdRemote("GolemForge")

        for _, t in ipairs(placed:GetChildren()) do
            if t:GetAttribute("OwnerUserId") == LocalPlayer.UserId and t:GetAttribute("HouseName") == house.Name then
                local ttype = t:GetAttribute("TowerType")
                if type(ttype) == "string" then
                    if vaultRf then
                        local gx, gz = t:GetAttribute("GridX"), t:GetAttribute("GridZ")
                        if type(gx) == "number" and type(gz) == "number" then
                            local okB, isBank = pcall(TowerConfig.IsBankTower, ttype)
                            if okB and isBank and now - (recentBank[t] or 0) > 2.5 then
                                local okR, cashIn, _, stats = pcall(TowerConfig.ReadBank, t)
                                if okR and type(cashIn) == "number" and cashIn >= 1 then
                                    local mx = type(stats) == "table" and stats.Max or nil
                                    if not mx or cashIn >= mx * (minBankPct / 100) then
                                        ensureNearWorldPos(t:GetPivot().Position, true)
                                        recentBank[t] = now
                                        vaultRf:FireServer(gx, gz)
                                    end
                                end
                            end
                        end
                    end
                    if forgeRf and type(TowerConfig.IsForgeTower) == "function" then
                        local okF, isForge = pcall(TowerConfig.IsForgeTower, ttype)
                        if okF and isForge and t:GetAttribute("ForgeState") == "Ready" and now - (recentForge[t] or 0) > 2.5 then
                            recentForge[t] = now
                            forgeRf:FireServer(t)
                        end
                    end
                end
            end
        end
    end

    -- ---------------------------------------------------------------- AUTO WIN STRATEGY PLANNER
    local function getMultiTargetMult(tt, lvl)
        if TowerConfig and type(TowerConfig.IsAoeTower) == "function" then
            local okA, isAoe = pcall(TowerConfig.IsAoeTower, tt)
            if okA and isAoe == true then return 1.45 end
        end
        if TowerConfig and type(TowerConfig.GetCombatStats) == "function" then
            local okC, cs = pcall(TowerConfig.GetCombatStats, tt, lvl)
            if okC and type(cs) == "table" then
                if (tonumber(cs.ChainTargets) or 0) >= 2 then return 1.45 end
                if (tonumber(cs.SplashRadius) or 0) > 0 then return 1.4 end
                if (tonumber(cs.ConeAngle) or tonumber(cs.ConeAngleDegrees) or 0) > 0 then return 1.35 end
            end
        end
        if tt == "FlamethrowerTurret" then return 1.35 end
        if tt == "TeslaTurret" or tt == "LavaLauncher" then return 1.45 end
        if tt == "MissileTower" or tt == "MortarTurret" or tt == "MortarMachine" or tt == "WorldEnderTurret" then return 1.4 end
        return 1.0
    end

    local lastAnyBuild, lastSellTick, lastFarmSellTick = 0, 0, 0
    local recentBuildByType = {}

    local function tryPlaceSmart(buildRf, pick, house, ownedTowers, combatCount, now, houseTowers)
        if not (buildRf and pick) then return false end
        if now - lastAnyBuild < 0.85 then return false end
        if now - (recentBuildByType[pick.name] or 0) < 1.5 then return false end
        local cell, freeCount = pickSmartCell(house, pick.name, houseTowers or ownedTowers)
        -- Only replace when grid is 100% full AND placing a strictly stronger combat tower or needed support buff
        local pickIsCombat = isCombat(pick.name) and (pick.effScoreM or pick.dpsM or 0) > 0
        local pickIsSupport = isSupport(pick.name)
        local needReplace = (not cell) and (pickIsCombat or pickIsSupport)
        if needReplace and State.AutoReplaceWeak and now - lastSellTick > 2.0 and pick.cost >= 150 then
            local refundRf = tdRemote("StructRefund")
            local weakT, weakScore = nil, math.huge
            local pickEff = pick.effScoreM or pick.dpsM or 0
            -- For Support (e.g. MilitaryBase) on a full grid, prefer selling a Farm first before a weak combat tower
            if pickIsSupport then
                for _, t in ipairs(ownedTowers) do
                    local tt = t:GetAttribute("TowerType")
                    local lvl = t:GetAttribute("Level") or 1
                    if type(tt) == "string" and isIncome(tt) and tt ~= "MoneyMachine" then
                        if lvl < weakScore then
                            weakScore = lvl
                            weakT = t
                        end
                    end
                end
            end
            if not weakT then
                weakScore = math.huge
                for _, t in ipairs(ownedTowers) do
                    local tt = t:GetAttribute("TowerType")
                    local lvl = t:GetAttribute("Level") or 1
                    if type(tt) == "string" and tt ~= pick.name and isCombat(tt) then
                        local okC, c = pcall(TowerConfig.GetPlaceCost, tt)
                        local okM, mxL = pcall(TowerConfig.GetMaxLevel, tt)
                        local ownedCap = tonumber(attr("TowerMax_" .. tt))
                        local effL = (ownedCap and ownedCap > 0) and math.min((okM and type(mxL) == "number") and mxL or 8, ownedCap) or ((okM and type(mxL) == "number") and mxL or 8)
                        local okDM, dm = pcall(TowerConfig.GetDps, tt, effL)
                        local okD, d = pcall(TowerConfig.GetDps, tt, lvl)
                        local oldEffMax = ((okDM and type(dm) == "number") and dm or 0) * getMultiTargetMult(tt, effL)
                        local sc = (okD and type(d) == "number" and d or 0) + (okC and type(c) == "number" and c * 0.1 or 0)
                        local strictlyStronger = pickIsSupport or (oldEffMax < pickEff * 0.88)
                        if strictlyStronger and sc < weakScore then
                            weakScore = sc
                            weakT = t
                        end
                    end
                end
            end
            if refundRf and weakT then
                local gx, gz = weakT:GetAttribute("GridX"), weakT:GetAttribute("GridZ")
                if type(gx) == "number" and type(gz) == "number" then
                    ensureNearWorldPos(weakT:GetPivot().Position, true)
                    lastSellTick = os.clock()
                    if isIncome(weakT:GetAttribute("TowerType")) then
                        lastFarmSellTick = lastSellTick
                    end
                    refundRf:FireServer(gx, gz)
                    if not cell then return false end
                end
            end
        end
        if not cell then return false end
        ensureNearWorldPos(cell.world, true)
        now = os.clock()
        recentCell[cell.key] = now
        recentBuildByType[pick.name] = now
        lastAnyBuild = now
        buildRf:FireServer(pick.name, cell.cx, cell.cz)
        return true
    end

    -- ---------------- PVP AI SYSTEM (Draft Ban/Pick + Send Eco/Rush + Abilities) ----------------
    local pvpState = nil
    local lastPvPBanRound, lastPvPPickDone = nil, false
    local lastPvPSendTick, lastPvPAbilityTick, lastPvPDoorTick = 0, 0, 0
    local currentEnemyDoorTarget = 1

    local PVP_THREAT_WEIGHT = {
        GolemForge = 120, DivineBank = 115, MortarMachine = 110, CrusherTower = 108,
        WorldEnderTurret = 105, RailgunTurret = 102, SamuraiTower = 98, VoidFarm = 96,
        LavaLauncher = 94, MilitaryBase = 88, ToxicTurret = 86, IceTurret = 84,
        FireSpitterTurret = 82, BallistaTower = 80, VaultFarm = 74, MedicalBase = 72,
        TeslaTurret = 68, FlamethrowerTurret = 64, MissileTower = 62, MiningCaveFarm = 58,
        Pet_Horse = 95, Pet_Dragon = 90, Pet_Bunny = 88,
    }
    local PVP_RARITY_WEIGHT = { Divine = 90, Legendary = 80, Mythic = 70, Epic = 50, Rare = 35, Common = 15 }
    local PVP_PET_PRIORITY = { Pet_Horse = 100, Pet_Dragon = 90, Pet_Bunny = 85, Pet_Deer = 70 }

    local function buildPvPBannedSet(st)
        local banned = {}
        if st and type(st.Bans) == "table" then
            for _, b in ipairs(st.Bans) do
                if type(b) == "table" and b.Id then
                    banned[b.Id] = true
                elseif type(b) == "string" then
                    banned[b] = true
                end
            end
        end
        return banned
    end

    local function computeBestPvPPicks(st, bannedSet)
        if not (st and type(st.You) == "table") then return {}, {} end
        tryLoadMatchModules()
        local slots = (PvPConfig and PvPConfig.Draft and tonumber(PvPConfig.Draft.Slots)) or 6
        local exT = (PvPConfig and PvPConfig.ExcludedTowers) or {}
        local exP = (PvPConfig and PvPConfig.ExcludedPets) or {}

        local ownedT, ownedSetT = {}, {}
        for _, id in ipairs(st.You.OwnedTowers or {}) do
            if type(id) == "string" and not bannedSet[id] and not exT[id] then
                ownedSetT[id] = true
                ownedT[#ownedT + 1] = id
            end
        end

        local scoredCombat, scoredEco = {}, {}
        for _, id in ipairs(ownedT) do
            if id ~= "MoneyMachine" and not isSupport(id) then
                if isIncome(id) then
                    local okM, mx = pcall(TowerConfig and TowerConfig.GetMaxLevel or function() return 8 end, id)
                    mx = (okM and type(mx) == "number") and mx or 8
                    local okI, incM = pcall(TowerConfig and TowerConfig.GetEffectiveIncomePerSecond or function() return 0 end, id, mx)
                    local share = (PvPConfig and type(PvPConfig.FarmShare) == "function" and PvPConfig.FarmShare(id)) or 0.25
                    scoredEco[#scoredEco + 1] = { id = id, score = (okI and tonumber(incM) or 0) * share }
                else
                    local okC, cost = pcall(TowerConfig and TowerConfig.GetPlaceCost or function() return 100 end, id)
                    local okM, mx = pcall(TowerConfig and TowerConfig.GetMaxLevel or function() return 8 end, id)
                    mx = (okM and type(mx) == "number") and mx or 8
                    local okD, dpsM = pcall(TowerConfig and TowerConfig.GetDps or function() return 0 end, id, mx)
                    local okA, isAoe = pcall(TowerConfig and TowerConfig.IsAoeTower or function() return false end, id)
                    local cVal = (okC and type(cost) == "number") and cost or 100
                    local dVal = (okD and type(dpsM) == "number") and dpsM or 0
                    local bonus = (okA and isAoe == true) and 1.25 or 1.0
                    scoredCombat[#scoredCombat + 1] = { id = id, cost = cVal, dpsM = dVal, score = dVal * bonus }
                end
            end
        end
        table.sort(scoredCombat, function(a, b) return a.score > b.score end)
        table.sort(scoredEco, function(a, b) return a.score > b.score end)

        local picksT, pickedSet = {}, {}
        local function addTower(id)
            if id and ownedSetT[id] and not pickedSet[id] and #picksT < slots then
                pickedSet[id] = true
                picksT[#picksT + 1] = id
            end
        end

        -- 1) Always pick free MoneyMachine + best Support (MilitaryBase)
        addTower("MoneyMachine")
        for _, sup in ipairs(SUPPORT_BUFF_ORDER) do
            addTower(sup)
        end
        -- 2) Reserve 1 Pet slot if player owns a Pet
        local bestPets = {}
        for _, pid in ipairs(st.You.OwnedPets or {}) do
            if type(pid) == "string" and not bannedSet[pid] and not exP[pid] then
                bestPets[#bestPets + 1] = { id = pid, score = PVP_PET_PRIORITY[pid] or 40 }
            end
        end
        table.sort(bestPets, function(a, b) return a.score > b.score end)
        local petReserve = (#bestPets > 0) and 1 or 0
        local maxTowers = math.max(1, slots - petReserve)

        -- 3) Ensure 1 cheap wave-1/early defender (<= 250) + highest-DPS late game towers
        for _, c in ipairs(scoredCombat) do
            if c.cost <= 250 then
                addTower(c.id)
                break
            end
        end
        for _, c in ipairs(scoredCombat) do
            if #picksT >= math.max(3, maxTowers - (#scoredEco > 0 and 1 or 0)) then break end
            addTower(c.id)
        end
        if #scoredEco > 0 and #picksT < maxTowers then
            addTower(scoredEco[1].id)
        end
        for _, c in ipairs(scoredCombat) do
            if #picksT >= maxTowers then break end
            addTower(c.id)
        end

        local picksP = {}
        if #bestPets > 0 and (#picksT + #picksP) < slots then
            picksP[1] = bestPets[1].id
        end
        return picksT, picksP
    end

    local function computePvPBans(st)
        if not (st and type(st.Catalog) == "table") then return {} end
        local need = math.max(1, tonumber(st.BanCount) or 2)
        local bannedSet = buildPvPBannedSet(st)
        local _, customBanSet = parseCsvList(State.PvPCustomBans)
        local ownProtect = {}
        if State.PvPBanStyle ~= "แบนตัวเมต้าสูงสุด (ทุกตัว)" then
            local pT, pP = computeBestPvPPicks(st, bannedSet)
            for _, id in ipairs(pT) do ownProtect[id] = true end
            for _, id in ipairs(pP) do ownProtect[id] = true end
        end

        local candidates = {}
        local function pushList(arr)
            if type(arr) ~= "table" then return end
            for _, entry in ipairs(arr) do
                if type(entry) == "table" and entry.Id and not entry.Unbannable and not bannedSet[entry.Id] then
                    local baseW = PVP_THREAT_WEIGHT[entry.Id] or PVP_RARITY_WEIGHT[tostring(entry.Rarity or "")] or 25
                    local customBonus = customBanSet[entry.Id] and 250 or 0
                    local pen = (not customBanSet[entry.Id] and ownProtect[entry.Id]) and 65 or 0
                    candidates[#candidates + 1] = { id = entry.Id, score = baseW + customBonus - pen }
                end
            end
        end
        pushList(st.Catalog.Towers)
        pushList(st.Catalog.Pets)
        table.sort(candidates, function(a, b) return a.score > b.score end)

        local out = {}
        for i = 1, math.min(need, #candidates) do
            out[i] = candidates[i].id
        end
        return out
    end

    local function submitPvPDraft(forceNotify)
        local st = pvpState
        local act = pvpRemote("PvPAction")
        if not (st and act) then
            if forceNotify then notify("PvP Draft", "ยังไม่พบข้อมูล PvPState จากเซิร์ฟเวอร์", 3) end
            return
        end
        local phase = st.Phase or workspace:GetAttribute("PvPPhase")
        local you = st.You or {}
        if phase == "Ban" and not you.BanSubmitted then
            local roundKey = tonumber(st.Round) or 1
            if forceNotify or lastPvPBanRound ~= roundKey then
                local banIds = computePvPBans(st)
                if #banIds > 0 then
                    lastPvPBanRound = roundKey
                    pcall(function() act:FireServer("Draft", { Phase = "Ban", Ids = banIds }) end)
                    task.wait(0.12)
                    pcall(function() act:FireServer("Ban", { Ids = banIds }) end)
                    notify("PvP Auto Ban (R" .. roundKey .. ")", "แบน: " .. table.concat(banIds, ", "), 4)
                end
            end
        elseif phase == "Pick" and not you.PickSubmitted then
            if forceNotify or not lastPvPPickDone then
                local bannedSet = buildPvPBannedSet(st)
                local pickT, pickP = computeBestPvPPicks(st, bannedSet)
                if (#pickT + #pickP) > 0 then
                    lastPvPPickDone = true
                    pcall(function() act:FireServer("Draft", { Phase = "Pick", Towers = pickT, Pets = pickP }) end)
                    task.wait(0.12)
                    pcall(function() act:FireServer("Pick", { Towers = pickT, Pets = pickP, Pet = pickP[1] }) end)
                    notify("PvP Auto Pick", "เลือก: " .. table.concat(pickT, ", ") .. (#pickP > 0 and (" | Pet: " .. table.concat(pickP, ", ")) or ""), 5)
                end
            end
        elseif forceNotify then
            notify("PvP Draft", "เฟสปัจจุบัน (" .. tostring(phase) .. ") ส่งข้อมูลแล้วหรือไม่ใช่หน้า Ban/Pick", 3)
        end
    end
    pvpTriggerDraftNow = function() submitPvPDraft(true) end

    local function findEnemyHousesPvP(mine)
        local hs = housesFolder()
        if not hs then return {} end
        local myTeam = tonumber(attr("PvPTeam"))
        local out = {}
        for _, h in ipairs(hs:GetChildren()) do
            if h ~= mine and (h:IsA("Model") or h:IsA("Folder")) then
                local hSide = tonumber(h:GetAttribute("PvPSide"))
                local ownerId = tonumber(h:GetAttribute("OwnerUserId")) or 0
                local isAlly = (TowerConfig and TowerConfig.IsHouseMember and TowerConfig.IsHouseMember(h, LocalPlayer.UserId))
                    or (myTeam and hSide and hSide == myTeam)
                if not isAlly and (ownerId ~= 0 or hSide ~= nil) then
                    out[#out + 1] = h
                end
            end
        end
        return out
    end

    local function ensureOnPvPPad(pad)
        if not (pad and pad:IsA("BasePart")) then return false end
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return false end
        local dx = math.abs(hrp.Position.X - pad.Position.X)
        local dz = math.abs(hrp.Position.Z - pad.Position.Z)
        local dy = math.abs(hrp.Position.Y - pad.Position.Y)
        if dx > math.max(3, pad.Size.X * 0.42) or dz > math.max(3, pad.Size.Z * 0.42) or dy > 8 then
            hrp.CFrame = CFrame.new(pad.Position + Vector3.new(0, 3.2, 0))
            task.defer(ensureWindowVisible)
            task.wait(0.1)
        end
        return true
    end

    local function stepPvPOffense(house, curCash, combatCount, worstPct)
        if not isPvPMode() then return false end
        if (workspace:GetAttribute("PvPPhase") or (pvpState and pvpState.Phase)) ~= "Live" then return false end
        local act = pvpRemote("PvPAction")
        if not (act and PvPConfig) then return false end
        local now = os.clock()
        local wave = math.max(1, tonumber(pvpState and pvpState.Wave) or 1)
        local incomeTick = tonumber(pvpState and (pvpState.IncomeTick or pvpState.Income)) or 200
        local cooldowns = (pvpState and pvpState.Cooldowns) or {}
        local srvNow = workspace:GetServerTimeNow()
        local sendZone = house and house:FindFirstChild("SendZone")
        local sendPad = sendZone and sendZone:FindFirstChild("SendPad")
        local abilPad = sendZone and sendZone:FindFirstChild("AbilityPad")

        -- Pick weakest intact enemy door
        local enemies = findEnemyHousesPvP(house)
        local bestEnemyDoorPct, bestDoorIdx = 101, 1
        for _, eh in ipairs(enemies) do
            for _, d in ipairs(getDoorsInfo(eh)) do
                if not d.broken and d.pct < bestEnemyDoorPct then
                    bestEnemyDoorPct = d.pct
                    bestDoorIdx = d.index
                end
            end
        end
        if currentEnemyDoorTarget ~= bestDoorIdx and (now - lastPvPDoorTick) >= 1.5 then
            lastPvPDoorTick = now
            currentEnemyDoorTarget = bestDoorIdx
            pcall(function() act:FireServer("Door", { Target = bestDoorIdx }) end)
        end

        -- 1) Tactical PvP Abilities (PvPClient: Attack skills use SendPad; Door/Tower skills use AbilityPad)
        if State.AutoPvPAbility and (sendPad or abilPad) and (now - lastPvPAbilityTick) >= 1.5 then
            local function tryAbility(id)
                local def = PvPConfig.GetAbility and PvPConfig.GetAbility(id)
                if not def then return false end
                if wave < (tonumber(def.From) or 1) then return false end
                if srvNow < (tonumber(cooldowns[id]) or 0) then return false end
                local pad = (def.Kind == "Attack") and sendPad or abilPad
                if not pad then return false end
                local cost = PvPConfig.AbilityCost(def, incomeTick)
                if curCash < cost then return false end
                lastPvPAbilityTick = os.clock()
                ensureOnPvPPad(pad)
                pcall(function() act:FireServer("Ability", { Id = id }) end)
                return true
            end
            if worstPct and worstPct < 60 then
                if tryAbility("Barricade") then return true end
                if tryAbility("FrostNova") then return true end
            end
            if worstPct and worstPct < 82 then
                if tryAbility("Overclock") then return true end
                if tryAbility("PowerSurge") then return true end
                if tryAbility("EagleEye") then return true end
            end
            if (bestEnemyDoorPct < 70 or (wave >= 15 and curCash >= 900)) and State.PvPSendMode ~= "ปิด (ไม่ส่งมอน)" then
                if tryAbility("Purge") then return true end
                if tryAbility("Bloodlust") then return true end
                if tryAbility("BulkUp") then return true end
                if tryAbility("Frenzy") then return true end
            end
        end

        -- 2) Auto Send Eco / Rush Monsters
        if State.PvPSendMode == "ปิด (ไม่ส่งมอน)" or not sendPad then return false end
        if (now - lastPvPSendTick) < 0.75 then return false end
        local queueLen = (pvpState and type(pvpState.Queue) == "table") and #pvpState.Queue or 0
        if queueLen >= 5 then return false end
        -- Don't starve base defense if door already under heavy pressure
        if combatCount < 2 or (worstPct and worstPct < 65) then return false end

        local minEcoReserve = (wave < 5 and 80) or 140
        local availCash = curCash - ((State.PvPSendMode ~= "สาย Rush ถล่มประตูไว" and combatCount < 4) and minEcoReserve or 0)
        if availCash <= 0 then return false end

        local chosenSend = nil
        local wantRush = (State.PvPSendMode == "สาย Rush ถล่มประตูไว")
            or (State.PvPSendMode == "สมดุล Eco + Rush ชนะไว" and (bestEnemyDoorPct <= 55 or wave >= 22 or (wave >= 15 and curCash >= 2500)))

        if wantRush then
            local bestRushPower = -1
            for _, sDef in ipairs(PvPConfig.Sends or {}) do
                if PvPConfig.IsSendAvailable(sDef, wave) and availCash >= sDef.Cost and sDef.Cost >= 250 then
                    local power = sDef.Cost * (sDef.Income <= 0 and 1.35 or 1.0)
                    if power > bestRushPower then
                        bestRushPower = power
                        chosenSend = sDef
                    end
                end
            end
        end

        if not chosenSend and State.PvPSendMode ~= "สาย Rush ถล่มประตูไว" then
            local bestPayback = math.huge
            for _, sDef in ipairs(PvPConfig.Sends or {}) do
                if PvPConfig.IsSendCurrent(sDef, wave) and sDef.Income > 0 and availCash >= sDef.Cost then
                    local pb = PvPConfig.PaybackSeconds(sDef) or math.huge
                    if pb < bestPayback or (math.abs(pb - bestPayback) < 1 and sDef.Income > (chosenSend and chosenSend.Income or 0)) then
                        bestPayback = pb
                        chosenSend = sDef
                    end
                end
            end
        end

        if not chosenSend then return false end
        lastPvPSendTick = os.clock()
        ensureOnPvPPad(sendPad)
        pcall(function() act:FireServer("Send", { Id = chosenSend.Id, Door = bestDoorIdx }) end)
        return true
    end

    getPvPStatusText = function()
        if not isPvPMode() then
            return "โหมดปัจจุบัน: PvE / ปกติ (PvP AI จะทำงานอัตโนมัติเมื่อเข้าด่าน PvP)"
        end
        local phase = (pvpState and pvpState.Phase) or tostring(workspace:GetAttribute("PvPPhase") or "?")
        local wave = (pvpState and pvpState.Wave) or 1
        local inc = (pvpState and (pvpState.IncomeTick or pvpState.Income)) or 200
        local q = (pvpState and type(pvpState.Queue) == "table") and #pvpState.Queue or 0
        local mine = myHouse()
        local enemyStr = "-"
        if mine then
            local parts = {}
            for _, eh in ipairs(findEnemyHousesPvP(mine)) do
                local w = worstDoorPct(eh)
                parts[#parts + 1] = string.format("%s:%.0f%%", eh.Name, w or 100)
            end
            if #parts > 0 then enemyStr = table.concat(parts, ", ") end
        end
        return string.format(
            "PvP [%s] Wave: %s | รายได้/6s: +%s | คิวส่ง: %d/5\nประตูศัตรู: %s\nโหมดส่งมอน: %s",
            tostring(phase), tostring(wave), tostring(math.floor(inc)), q, enemyStr, tostring(State.PvPSendMode)
        )
    end

    -- Hydrate & listen to live PvPState + PvPMapVote + TeamUpRequest
    local lastMapVoteDone = false
    local pvpVoteEv = pvpRemote("PvPMapVote")
    if pvpVoteEv and pvpVoteEv:IsA("RemoteEvent") then
        track(pvpVoteEv.OnClientEvent:Connect(function(vSt)
            if State.AutoPvPDraft and not lastMapVoteDone and type(vSt) == "table" and vSt.Phase == "Voting" then
                lastMapVoteDone = true
                pcall(function() pvpVoteEv:FireServer(1) end)
            end
        end))
        if isPvPMode() and workspace:GetAttribute("PvPMapVoting") == true then
            task.spawn(function() pcall(function() pvpVoteEv:FireServer("Hello") end) end)
        end
    end

    local teamReqEv = tdRemote("TeamUpRequest")
    if teamReqEv and teamReqEv:IsA("RemoteEvent") then
        track(teamReqEv.OnClientEvent:Connect(function(cmd, payload)
            if cmd ~= "show" or type(payload) ~= "table" or type(payload.RequestId) ~= "string" then return end
            if State.AutoAcceptTeamUp == "ปิด" then return end
            local uid = tonumber(payload.UserId)
            local accept = (State.AutoAcceptTeamUp == "ทุกคน")
            if not accept and State.AutoAcceptTeamUp == "เฉพาะเพื่อน (Friends)" and uid then
                local okF, isF = pcall(function() return LocalPlayer:IsFriendsWith(uid) end)
                accept = (okF and isF == true)
            end
            if accept then
                local resp = tdRemote("TeamUpRespond")
                if resp then
                    task.delay(0.15, function()
                        pcall(function() resp:FireServer(payload.RequestId, true) end)
                    end)
                end
            end
        end))
    end

    local pvpStateEv = pvpRemote("PvPState")
    if pvpStateEv and pvpStateEv:IsA("RemoteEvent") then
        track(pvpStateEv.OnClientEvent:Connect(function(st)
            if type(st) ~= "table" then return end
            if pvpState and not st.Catalog then st.Catalog = pvpState.Catalog end
            if type(st.You) == "table" and pvpState and type(pvpState.You) == "table" then
                st.You.OwnedTowers = st.You.OwnedTowers or pvpState.You.OwnedTowers
                st.You.OwnedPets = st.You.OwnedPets or pvpState.You.OwnedPets
                st.You.Saved = st.You.Saved or pvpState.You.Saved
            end
            if st.Phase == "Ban" and st.Round ~= lastPvPBanRound then lastPvPBanRound = nil end
            if st.Phase ~= "Pick" then lastPvPPickDone = false end
            pvpState = st
            if State.AutoPvPDraft and (st.Phase == "Ban" or st.Phase == "Pick") then
                task.spawn(function() submitPvPDraft(false) end)
            end
        end))
        if isPvPMode() then
            task.spawn(function()
                local act = pvpRemote("PvPAction")
                if act then pcall(function() act:FireServer("Hello", {}) end) end
            end)
        end
    end

    local lastPlanSummary = "กำลังวิเคราะห์ฐานและชุดป้อม..."
    getStrategyPlanText = function()
        return lastPlanSummary
    end

    local recentTarget = setmetatable({}, { __mode = "k" })

    local function getHouseOccupants(house, houseTowers)
        if TowerConfig and type(TowerConfig.GetHouseOccupantCount) == "function" then
            local okN, n = pcall(TowerConfig.GetHouseOccupantCount, house)
            if okN and type(n) == "number" and n >= 1 then return math.floor(n) end
        end
        local uniq, cnt = {}, 0
        local ownerId = tonumber(house:GetAttribute("OwnerUserId")) or 0
        if ownerId > 0 then uniq[ownerId] = true cnt += 1 end
        for _, t in ipairs(houseTowers or {}) do
            local oid = tonumber(t:GetAttribute("OwnerUserId")) or 0
            if oid > 0 and not uniq[oid] then uniq[oid] = true cnt += 1 end
        end
        return math.max(1, cnt)
    end

    local function getMatchWaveAndBossInfo(house, inPvP)
        local gMode = (TowerConfig and type(TowerConfig.ResolveGameMode) == "function" and TowerConfig.ResolveGameMode())
            or workspace:GetAttribute("ResolvedGameMode")
            or workspace:GetAttribute("ActiveGameMode")
            or "Easy"
        local curWave, maxWave = 1, 25
        if inPvP then
            curWave = math.max(1, tonumber(pvpState and pvpState.Wave) or 1)
            maxWave = math.max(curWave, tonumber(pvpState and pvpState.MaxWave) or 30)
        else
            if TowerConfig and type(TowerConfig.GetMaxWave) == "function" then
                local okMW, mw = pcall(TowerConfig.GetMaxWave, gMode)
                if okMW and type(mw) == "number" and mw >= 1 and mw < 9999 then maxWave = mw end
            end
            local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
            local mhui = pg and pg:FindFirstChild("MonsterHudUI")
            local hr = mhui and mhui:FindFirstChild("HudRoot")
            local wb = hr and hr:FindFirstChild("WaveBadge")
            local wn = wb and wb:FindFirstChild("WaveNumber")
            local parsed = false
            if wn and wn:IsA("TextLabel") then
                local clean = tostring(wn.Text or ""):gsub("<[^>]+>", "")
                local cw, mw2 = clean:match("(%d+)%s*/%s*(%d+)")
                if cw then
                    curWave = math.max(1, tonumber(cw) or 1)
                    if mw2 and tonumber(mw2) then maxWave = tonumber(mw2) end
                    parsed = true
                else
                    local onlyW = clean:match("(%d+)")
                    if onlyW then curWave = math.max(1, tonumber(onlyW) or 1) parsed = true end
                end
            end
            if not parsed then
                curWave = math.max(1, 1 + math.floor(num(attr("MatchSeconds")) / 26))
            end
        end
        local bossLive = false
        if house then
            for i = 0, 4 do
                local suf = (i == 0) and "" or tostring(i)
                local bn = house:GetAttribute("DoorBossName" .. suf)
                local bt = tonumber(house:GetAttribute("DoorBossTick" .. suf)) or 0
                if (type(bn) == "string" and bn ~= "") or bt > 0 then bossLive = true break end
            end
        end
        if not bossLive then
            local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
            local bb = pg and pg:FindFirstChild("MonsterHudUI") and pg.MonsterHudUI:FindFirstChild("HudRoot") and pg.MonsterHudUI.HudRoot:FindFirstChild("BossBar")
            if bb and bb.Visible == true then bossLive = true end
        end
        return gMode, curWave, maxWave, bossLive
    end

    local function stepAutoTargeting(ownedTowers, now)
        local setRf = tdRemote("SetTowerTarget")
        if not (setRf and TowerTargeting and type(TowerTargeting.ModesFor) == "function") then return end
        for _, t in ipairs(ownedTowers) do
            local tt = t:GetAttribute("TowerType")
            local gx, gz = t:GetAttribute("GridX"), t:GetAttribute("GridZ")
            if type(tt) == "string" and type(gx) == "number" and type(gz) == "number"
                and TowerTargeting.AppliesTo(tt) and not TowerTargeting.IsSpinner(tt)
                and now - (recentTarget[t] or 0) > 0.55 then
                local okR, rng = pcall(TowerConfig.GetTowerRange, tt, 1)
                local longRng = (okR and type(rng) == "number" and rng >= 44)
                local isBossKiller = (tt == "TeslaTurret") or (longRng and tt ~= "FlamethrowerTurret")
                local want = "First"
                if isBossKiller and (math.floor(gx + gz) % 3 ~= 0) then
                    want = "WeakestBoss"
                end
                local cur = TowerTargeting.Of(t)
                if cur ~= want then
                    local modes = TowerTargeting.ModesFor(tt)
                    local ci, wi = table.find(modes, cur), table.find(modes, want)
                    if ci and wi and #modes > 0 then
                        local fwd = (wi - ci) % #modes
                        local bwd = (ci - wi) % #modes
                        local delta = (fwd <= bwd) and 1 or -1
                        recentTarget[t] = now
                        setRf:FireServer(gx, gz, delta)
                        return
                    end
                end
            end
        end
    end

    local function stepAutoWin()
        local now = os.clock()
        tryLoadMatchModules()
        local inPvP = isPvPMode()
        if inPvP then
            local phase = (pvpState and pvpState.Phase) or workspace:GetAttribute("PvPPhase")
            if State.AutoPvPDraft and (phase == "Ban" or phase == "Pick") then
                lastPlanSummary = "โหมด PvP (" .. tostring(phase) .. "): กำลังส่งคำสั่ง Auto Ban / Pick อัตโนมัติ"
                submitPvPDraft(false)
                return
            end
            if phase ~= "Live" then
                lastPlanSummary = "โหมด PvP (" .. tostring(phase or "Waiting") .. "): รอเข้าช่วงสู้..."
                return
            end
        end
        local house, cash = myHouse(), cashValue()
        local placed = workspace:FindFirstChild("PlacedTowers")
        if not (house and cash and placed and TowerConfig) then return end

        local curCash = cash.Value
        local doorCount = getDoorCount(house)

        drainAndForgeOwned(house, math.min(State.BankPct, 20))
        fireRepairIfReady(house, 99.9)
        local worstPct = worstDoorPct(house)
        if worstPct and worstPct < 48 then
            if fireDoorUpgrade(house, cash, 0, pickMostDamagedDoor(house)) then return end
        end

        local ownedTowers, houseTowers, countByType = {}, {}, {}
        local combatCount, ecoCount, supportCount, estIncomeRate, totalCombatDps = 0, 0, 0, 0, 0
        local teamCombatCount, teamEcoCount = 0, 0
        for _, t in ipairs(placed:GetChildren()) do
            if t:GetAttribute("HouseName") == house.Name then
                houseTowers[#houseTowers + 1] = t
                local tt = t:GetAttribute("TowerType")
                local lvl = t:GetAttribute("Level") or 1
                local isMine = (t:GetAttribute("OwnerUserId") == LocalPlayer.UserId)
                if type(tt) == "string" then
                    if isCombat(tt) then teamCombatCount += 1 elseif isIncome(tt) then teamEcoCount += 1 end
                end
                if isMine then
                    ownedTowers[#ownedTowers + 1] = t
                    if type(tt) == "string" then
                        countByType[tt] = (countByType[tt] or 0) + 1
                        if isIncome(tt) then
                            ecoCount += 1
                            local okInc, incVal = pcall(TowerConfig.GetEffectiveIncomePerSecond, tt, lvl)
                            if okInc and type(incVal) == "number" then estIncomeRate += incVal end
                        elseif isSupport(tt) then
                            supportCount += 1
                        elseif isCombat(tt) then
                            combatCount += 1
                            local okD, dVal = pcall(TowerConfig.GetDps, tt, lvl)
                            if okD and type(dVal) == "number" then totalCombatDps += dVal end
                        end
                    end
                end
            end
        end

        local occupants = getHouseOccupants(house, houseTowers)
        local isTeamHouse = (occupants >= 2)
        local gMode, curWave, maxWave, bossLive = getMatchWaveAndBossInfo(house, inPvP)
        local isHardPlus = (gMode == "Nightmare" or gMode == "Impossible" or gMode == "Crazy" or gMode == "Halloween")
        local pvpWave = inPvP and curWave or 0

        local buildRf = tdRemote("BuildRequest")
        local loadout = loadoutTypes()

        local freeList, combatList, ecoList, supportList = {}, {}, {}, {}
        local totalEcoLimit = 0
        for _, tt in ipairs(loadout) do
            local okC, cost = pcall(TowerConfig.GetPlaceCost, tt)
            local okL, limit
            if inPvP and type(TowerConfig.GetPvPPlacementLimit) == "function" then
                okL, limit = pcall(TowerConfig.GetPvPPlacementLimit, tt)
            else
                okL, limit = pcall(TowerConfig.GetPlacementLimit, tt)
            end
            local okM, mxLv = pcall(TowerConfig.GetMaxLevel, tt)
            mxLv = (okM and type(mxLv) == "number") and mxLv or 8
            local ownedCap = tonumber(attr("TowerMax_" .. tt))
            local effMaxLv = (ownedCap and ownedCap > 0) and math.min(mxLv, ownedCap) or mxLv
            if okC and type(cost) == "number" then
                limit = (okL and type(limit) == "number") and limit or 8
                local have = countByType[tt] or 0
                local okD1, dps1 = pcall(TowerConfig.GetDps, tt, 1)
                local okDM, dpsM = pcall(TowerConfig.GetDps, tt, effMaxLv)
                local okI1, inc1 = pcall(TowerConfig.GetEffectiveIncomePerSecond, tt, 1)
                local okIM, incM = pcall(TowerConfig.GetEffectiveIncomePerSecond, tt, effMaxLv)
                local entry = {
                    name = tt,
                    cost = cost,
                    limit = limit,
                    have = have,
                    dps1 = (okD1 and type(dps1) == "number") and dps1 or 0,
                    dpsM = (okDM and type(dpsM) == "number") and dpsM or 0,
                    effScoreM = ((okDM and type(dpsM) == "number") and dpsM or 0) * getMultiTargetMult(tt, effMaxLv),
                    inc1 = (okI1 and type(inc1) == "number") and inc1 or 0,
                    incM = (okIM and type(incIM) == "number") and incM or 0,
                }
                if cost <= 0 or isIncome(tt) then
                    totalEcoLimit += limit
                end
                if have < limit then
                    if cost <= 0 then
                        freeList[#freeList + 1] = entry
                    elseif isIncome(tt) then
                        ecoList[#ecoList + 1] = entry
                    elseif isSupport(tt) then
                        supportList[#supportList + 1] = entry
                    else
                        combatList[#combatList + 1] = entry
                    end
                end
            end
        end

        -- 1) Free towers always first (MoneyMachine Cost=0!)
        if tryPlaceSmart(buildRf, freeList[1], house, ownedTowers, combatCount, now, houseTowers) then
            return
        end

        -- Score Combat: early -> cheapest Wave-1 defender so all doors get covered immediately; mid/late -> highest capped AoE-weighted DPS
        local earlyDefensePhase = (combatCount < math.max(2, doorCount * 2))
        table.sort(combatList, function(a, b)
            if earlyDefensePhase then
                if a.cost ~= b.cost and (a.cost <= 250 or b.cost <= 250) then
                    return a.cost < b.cost
                end
                local va = a.dps1 / math.max(a.cost, 1)
                local vb = b.dps1 / math.max(b.cost, 1)
                if math.abs(va - vb) > 0.002 then return va > vb end
                return a.cost < b.cost
            end
            if math.abs(a.effScoreM - b.effScoreM) > 1 then return a.effScoreM > b.effScoreM end
            return a.dps1 > b.dps1
        end)

        -- Score Economy: prefer highest efficiency farm early, highest max income farm once scaling
        table.sort(ecoList, function(a, b)
            if curCash < 260 or ecoCount < 3 then
                local ra = a.inc1 / math.max(a.cost, 1)
                local rb = b.inc1 / math.max(b.cost, 1)
                if math.abs(ra - rb) > 0.002 then return ra > rb end
                return a.cost < b.cost
            end
            return a.incM > b.incM
        end)

        local cellsNow = freeCellsDetailed(house)
        local totalGridCells = math.max(20, #cellsNow + #houseTowers)
        local soloCombatReserve = math.max(18, math.floor(totalGridCells * 0.58))
        local soloGridFarmCap = math.max(10, math.min(14, totalGridCells - soloCombatReserve))
        local soloEcoCap = math.min(soloGridFarmCap, math.max(8, totalEcoLimit > 0 and totalEcoLimit or 14))
        local teamEcoCap = isTeamHouse and math.max(3, math.floor(14 / occupants)) or soloEcoCap
        local lateEndgameSell = (not inPvP and State.AutoReplaceWeak and curWave >= math.max(10, maxWave - 3) and totalCombatDps >= 1200)
        local desiredEcoMin
        if inPvP then
            if pvpWave >= 18 or State.PvPSendMode == "สาย Rush ถล่มประตูไว" or combatCount < 3 then
                desiredEcoMin = 0
            elseif isTeamHouse then
                desiredEcoMin = 1
            else
                desiredEcoMin = 2
            end
        elseif lateEndgameSell then
            desiredEcoMin = isTeamHouse and 2 or 5
        elseif isTeamHouse then
            desiredEcoMin = math.min(teamEcoCap, math.max(3, 2 + math.floor(curWave * 0.45)))
        elseif State.WinStyle == "Eco & MoneyRush (ตั้งฐานปั๊มเงินไว)" then
            desiredEcoMin = math.min(soloEcoCap + 2, math.max(8, 5 + curWave))
        elseif State.WinStyle == "Cheap DPS Rush (วางป้อมถูกแรงไว)" then
            desiredEcoMin = math.min(8, soloEcoCap)
        else
            desiredEcoMin = math.min(soloEcoCap, math.max(6, 4 + curWave))
        end

        -- 2) Guarantee every door gets defended right away (Nightmare/PvP prioritize >= 1 defender per door before Farms)
        local minEarlyCombat = (inPvP or isHardPlus) and math.max(2, doorCount) or math.max(1, doorCount)
        if buildRf and teamCombatCount < minEarlyCombat and #combatList > 0 then
            local pick = combatList[1]
            if curCash >= pick.cost and tryPlaceSmart(buildRf, pick, house, ownedTowers, combatCount, now, houseTowers) then return end
            return
        end

        -- 2.5) In PvP: run Eco Sends / Rush / Abilities once baseline defense is standing
        if inPvP and stepPvPOffense(house, curCash, teamCombatCount, worstPct) then
            return
        end

        -- 3) Evaluate best ROI upgrade across owned towers
        local okDL, curDoorLvl = pcall(TowerConfig.GetDoorLevel, house)
        curDoorLvl = (okDL and type(curDoorLvl) == "number") and curDoorLvl or 1
        local lowestDoor = pickLowestDoor(house)
        local lowestDoorLv = (lowestDoor and lowestDoor.level) or curDoorLvl

        local upRf = tdRemote("StructRaise")
        local bestAffordable, topROI, topEcoUp = nil, nil, nil
        local blockedByDoor = false
        local maxReqDoorLvl = lowestDoorLv

        for _, t in ipairs(ownedTowers) do
            local gx, gz = t:GetAttribute("GridX"), t:GetAttribute("GridZ")
            local tt, lvl = t:GetAttribute("TowerType"), t:GetAttribute("Level") or 1
            if type(gx) == "number" and type(gz) == "number" and type(tt) == "string" and type(lvl) == "number" then
                local capA = t:GetAttribute("LevelCap")
                local ownedCap = tonumber(attr("TowerMax_" .. tt))
                local okM, mx = pcall(TowerConfig.GetMaxLevel, tt)
                local cap = math.min(
                    type(capA) == "number" and capA or math.huge,
                    (ownedCap and ownedCap > 0) and ownedCap or math.huge,
                    (okM and type(mx) == "number") and mx or math.huge
                )
                if lvl < cap then
                    local okR, reqDoor = pcall(TowerConfig.GetRequiredDoorLevel, lvl + 1)
                    if okR and type(reqDoor) == "number" then
                        if reqDoor > lowestDoorLv then
                            blockedByDoor = true
                            if reqDoor > maxReqDoorLvl then maxReqDoorLvl = reqDoor end
                        else
                            local okC, uCost = pcall(TowerConfig.GetUpgradeCost, tt, lvl)
                            if okC and type(uCost) == "number" then
                                local rec = recentUp[t]
                                if not rec or rec.level ~= lvl or now - rec.t > 1.5 then
                                    local eco = isIncome(tt)
                                    local sup = isSupport(tt)
                                    local skipEcoPayback = false
                                    local roi = 1 / math.max(uCost, 1)
                                    local rawGainPerDollar = roi
                                    if eco then
                                        local ok1, i1 = pcall(TowerConfig.GetEffectiveIncomePerSecond, tt, lvl)
                                        local ok2, i2 = pcall(TowerConfig.GetEffectiveIncomePerSecond, tt, lvl + 1)
                                        local gain = ((ok2 and tonumber(i2) or 0) - (ok1 and tonumber(i1) or 0))
                                        local remSec = inPvP and 360 or math.max(25, (maxWave - curWave + 1) * 24)
                                        local paybackSec = uCost / math.max(gain, 0.01)
                                        if not inPvP and paybackSec > remSec * 0.72 then
                                            skipEcoPayback = true
                                        end
                                        rawGainPerDollar = math.max(gain, 0.1) / math.max(uCost, 1)
                                        roi = rawGainPerDollar * (((curWave <= math.floor(maxWave * 0.68) or ecoCount < desiredEcoMin) and (not worstPct or worstPct >= 65)) and 2.4 or 1.1)
                                    elseif sup then
                                        local effGain = math.max(teamCombatCount * 15, totalCombatDps * 0.22)
                                        rawGainPerDollar = effGain / math.max(uCost, 1)
                                        roi = rawGainPerDollar
                                    else
                                        local ok1, d1 = pcall(TowerConfig.GetDps, tt, lvl)
                                        local ok2, d2 = pcall(TowerConfig.GetDps, tt, lvl + 1)
                                        local gain = ((ok2 and tonumber(d2) or 0) - (ok1 and tonumber(d1) or 0))
                                        local aoeMult = getMultiTargetMult(tt, lvl + 1)
                                        rawGainPerDollar = (math.max(gain, 0.1) * aoeMult) / math.max(uCost, 1)
                                        roi = rawGainPerDollar * (((worstPct and worstPct < 80) or bossLive) and 2.0 or 1.0)
                                    end
                                    if not skipEcoPayback then
                                        local cand = { t = t, gx = gx, gz = gz, cost = uCost, lvl = lvl, tt = tt, roi = roi, rawRoi = rawGainPerDollar, isEco = eco }
                                        if eco and (not topEcoUp or cand.rawRoi > topEcoUp.rawRoi) then
                                            topEcoUp = cand
                                        end
                                        if not topROI or cand.roi > topROI.roi then
                                            topROI = cand
                                        end
                                        if cand.cost <= curCash and (not bestAffordable or cand.roi > bestAffordable.roi) then
                                            bestAffordable = cand
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Realistic target door level: zero drain on W1-2 so Eco + Turrets snowball first, then scales HP cleanly
        local targetDoorLv = maxReqDoorLvl
        if State.AutoDoorTargetUp then
            if inPvP then
                targetDoorLv = math.max(maxReqDoorLvl, math.min(20, 1 + math.floor(math.max(0, pvpWave - 2) * 0.5)))
            elseif isHardPlus then
                targetDoorLv = math.max(maxReqDoorLvl, math.min(20, 1 + math.floor(math.max(0, curWave - 2) * 0.45)))
            else
                targetDoorLv = math.max(maxReqDoorLvl, math.min(14, 1 + math.floor(math.max(0, curWave - 2) * 0.42)))
            end
        end
        local dCost = getNextDoorUpgradeCost(house, nil)
        local needDoorEmergency = (worstPct and worstPct < 52) or (bossLive and worstPct and worstPct < 68 and lowestDoorLv < targetDoorLv + 2)
        local ecoMinForDoor = math.min(desiredEcoMin, isTeamHouse and 2 or 3)
        local combatMinForDoor = math.min(10, math.max(doorCount * 2, 2 + math.floor(curWave * 0.5)))
        local needDoorTarget = State.AutoDoorTargetUp and (lowestDoorLv < targetDoorLv)
            and (ecoCount >= ecoMinForDoor) and (teamCombatCount >= combatMinForDoor)

        local modeLabel = inPvP and ("PvP W" .. pvpWave) or string.format("%s W%d/%d (%s)", gMode, curWave, maxWave, isTeamHouse and ("ทีม " .. occupants) or "เดี่ยว")
        lastPlanSummary = string.format(
            "โหมด: %s | ประตู Lv.%d (เป้า Lv.%d) | ฟาร์ม %d/%d | ป้อมยิง %d/%d | ช่องว่าง %d\nแผนถัดไป: %s%s",
            modeLabel, lowestDoorLv, targetDoorLv, ecoCount, desiredEcoMin, combatCount, teamCombatCount, #cellsNow,
            needDoorEmergency and string.format("กู้ประตู Lv.%d ($%d)", lowestDoorLv + 1, tonumber(dCost) or 0)
                or (topROI and string.format("%s Lv.%d->%d ($%d)", topROI.tt, topROI.lvl, topROI.lvl + 1, topROI.cost)
                or (needDoorTarget and string.format("อัปประตู Lv.%d ($%d)", lowestDoorLv + 1, tonumber(dCost) or 0) or "ทุกตัวเต็ม/รอวางเพิ่ม")),
            bossLive and " | [BOSS ACTIVE]" or ""
        )

        -- 3.5) True Emergency Door Rescue ONLY (<52% HP, or Boss hammering <68% HP); never sell your last <=2 Farms uselessly
        if needDoorEmergency and (#ownedTowers >= 1) then
            if dCost and curCash >= dCost then
                if fireDoorUpgrade(house, cash, 0, pickMostDamagedDoor(house)) then return end
            elseif State.AutoReplaceWeak and worstPct and worstPct < 45 and now - lastSellTick > 2.5 then
                local refundRf = tdRemote("StructRefund")
                local farms = {}
                for _, t in ipairs(ownedTowers) do
                    local tt = t:GetAttribute("TowerType")
                    if type(tt) == "string" and isIncome(tt) and tt ~= "MoneyMachine" then farms[#farms + 1] = t end
                end
                if refundRf and #farms > 2 then
                    table.sort(farms, function(a, b) return (a:GetAttribute("Level") or 1) < (b:GetAttribute("Level") or 1) end)
                    local v = farms[1]
                    local gx, gz = v:GetAttribute("GridX"), v:GetAttribute("GridZ")
                    if type(gx) == "number" and type(gz) == "number" then
                        ensureNearWorldPos(v:GetPivot().Position, true)
                        lastSellTick = os.clock()
                        refundRf:FireServer(gx, gz)
                        return
                    end
                end
            end
        end

        -- 4) Scale Economy fast (12-14 Farms -> $800-$2,000/s) while checking real Door threat & never rebuilding sold Farms!
        local keepFloorSlots = isTeamHouse and 5 or 3
        local doorUnlockReady = blockedByDoor and dCost and curCash >= dCost
        local doorTakingHeat = worstPct and (worstPct < 55 or (bossLive and worstPct < 65))
        if not doorUnlockReady and doorTakingHeat and #ownedTowers >= 1 then
            if dCost and curCash >= dCost then
                if fireDoorUpgrade(house, cash, 0, pickMostDamagedDoor(house)) then return end
            end
        end
        local doorCheapByIncome = dCost and curCash >= dCost and (dCost <= estIncomeRate * 4.5 or dCost <= curCash * 0.30)
        if not doorUnlockReady and not doorTakingHeat and needDoorTarget and ecoCount >= 4 and doorCheapByIncome then
            if fireDoorUpgrade(house, cash, 0) then return end
        end
        local ecoMinDoorPct = (ecoCount < 6) and 55 or 62
        local farmSoldRecently = (now - lastFarmSellTick < 30)
        local remSecForNewFarm = inPvP and 360 or math.max(25, (maxWave - curWave + 1) * 24)
        local canPlaceNewFarm = (not farmSoldRecently) and (not lateEndgameSell) and (#cellsNow > keepFloorSlots)
            and (#ecoList > 0) and (inPvP or (ecoList[1].cost / math.max(ecoList[1].inc1, 0.1)) <= remSecForNewFarm * 0.60)
        if buildRf and not doorUnlockReady and not doorTakingHeat and ecoCount < desiredEcoMin and #ecoList > 0 and (not worstPct or worstPct >= ecoMinDoorPct) and (canPlaceNewFarm or topEcoUp) then
            local ecoPick = ecoList[1]
            local newFarmRoi = ecoPick.inc1 / math.max(ecoPick.cost, 1)
            local preferEcoUpgrade = (not canPlaceNewFarm)
                or (topEcoUp and (topEcoUp.rawRoi >= newFarmRoi * 0.92) and (topEcoUp.cost <= math.max(curCash * 2.0, curCash + math.max(300, estIncomeRate * 4))))
            local targetEcoCost = preferEcoUpgrade and (topEcoUp and topEcoUp.cost or math.huge) or ecoPick.cost
            local needStarterFarms = (ecoCount < math.min(4, desiredEcoMin))
                or (ecoCount < math.min(8, desiredEcoMin) and combatCount >= math.max(4, doorCount * 2))
            local shortWaitForFarm = targetEcoCost <= math.max(curCash * 1.45, curCash + math.max(120, estIncomeRate * 3))
            local allowEcoWait = (not worstPct or worstPct >= 60) and (needStarterFarms or shortWaitForFarm)
            if preferEcoUpgrade then
                if upRf and topEcoUp and curCash >= topEcoUp.cost then
                    ensureNearWorldPos(topEcoUp.t:GetPivot().Position, true)
                    recentUp[topEcoUp.t] = { level = topEcoUp.lvl, t = os.clock() }
                    upRf:FireServer(topEcoUp.gx, topEcoUp.gz)
                    return
                end
                if allowEcoWait and topEcoUp then return end
            elseif canPlaceNewFarm then
                if curCash >= ecoPick.cost then
                    if tryPlaceSmart(buildRf, ecoPick, house, ownedTowers, combatCount, now, houseTowers) then return end
                elseif allowEcoWait then
                    return
                end
            end
        end

        -- 5) Unlock door immediately ONLY if towers are blocked by DoorLevel (or Emergency)
        if (blockedByDoor or needDoorEmergency) and (#ownedTowers >= math.max(2, doorCount) or needDoorEmergency) then
            if dCost and curCash >= dCost then
                if fireDoorUpgrade(house, cash, 0) then return end
            elseif blockedByDoor then
                if not bestAffordable or (bestAffordable.cost > dCost * 0.5) then return end
            end
        end

        local topSupport = supportList[1]
        local topCombat = combatList[1]

        -- 5.2) Final-2-Waves Cash-Out (e.g. Wave 24-25 Hard / Wave 39-40 Nightmare): sell dead Farms FIRST for instant cash & slots!
        local isFinalWaves = (not inPvP and State.AutoReplaceWeak and curWave >= math.max(10, maxWave - 1))
        if isFinalWaves and now - lastSellTick > 1.0 then
            local refundRf = tdRemote("StructRefund")
            local needCashOrSlots = (#cellsNow == 0)
                or (topCombat ~= nil)
                or (topSupport ~= nil and supportCount < 4)
                or (topROI and not topROI.isEco and topROI.cost > curCash)
                or (dCost and (blockedByDoor or lowestDoorLv < targetDoorLv) and dCost > curCash)
            if refundRf and needCashOrSlots then
                local farms = {}
                for _, t in ipairs(ownedTowers) do
                    local tt = t:GetAttribute("TowerType")
                    if type(tt) == "string" and isIncome(tt) and tt ~= "MoneyMachine" then
                        farms[#farms + 1] = t
                    end
                end
                if #farms > 0 then
                    table.sort(farms, function(a, b) return (a:GetAttribute("Level") or 1) > (b:GetAttribute("Level") or 1) end)
                    local victim = farms[1]
                    local gx, gz = victim:GetAttribute("GridX"), victim:GetAttribute("GridZ")
                    if type(gx) == "number" and type(gz) == "number" then
                        ensureNearWorldPos(victim:GetPivot().Position, true)
                        lastSellTick = os.clock()
                        lastFarmSellTick = lastSellTick
                        refundRf:FireServer(gx, gz)
                        return
                    end
                end
            end
        end

        -- 5.5) Place Support Buff / Healer tower early enough so MilitaryBase covers both door clusters before cells fill
        if buildRf and topSupport and curCash >= topSupport.cost then
            local wantHealerNow = (topSupport.name == "MedicalBase" or topSupport.name == "ProtectorTower") and teamCombatCount >= 1 and supportCount < doorCount
            local allowedBuffCount = (teamCombatCount >= 14 and 4)
                or (teamCombatCount >= 10 and (estIncomeRate >= 260 or totalCombatDps >= 600) and math.max(2, doorCount))
                or ((teamCombatCount >= 6 and (inPvP or estIncomeRate >= 150 or totalCombatDps >= 250)) and 1 or 0)
            local wantBuffNow = (topSupport.name ~= "MedicalBase" and topSupport.name ~= "ProtectorTower") and (supportCount < allowedBuffCount)
            if wantHealerNow or wantBuffNow then
                if tryPlaceSmart(buildRf, topSupport, house, ownedTowers, combatCount, now, houseTowers) then return end
            end
        end

        -- 5.8) Auto-set long-range heavy/sniper towers (2/3) to WeakestBoss while AoE/others stay First
        stepAutoTargeting(ownedTowers, now)

        -- Smart wait: don't burn cash on weak low-ROI upgrades when a high-ROI upgrade is a few seconds away
        local bestUp = bestAffordable
        if topROI and topROI.cost > curCash and ecoCount >= 2 and estIncomeRate >= 12 then
            local shortWait = topROI.cost <= math.max(curCash * 2.2, curCash + estIncomeRate * 6.0)
            if shortWait and (not bestAffordable or bestAffordable.roi < topROI.roi * 0.65) then
                bestUp = topROI
            end
        end
        bestUp = bestUp or topROI

        -- 6) Place next Combat tower (or upgrade-replace a weaker combat tower on a full grid when we have cash / late waves!)
        local waveCombatGoal = math.max(4, doorCount * 2) + math.floor(curWave * 0.45)
        if buildRf and topCombat and curCash >= topCombat.cost then
            local needBaseTurrets = combatCount < waveCombatGoal
            local newTurretRoi = topCombat.dps1 / math.max(topCombat.cost, 1)
            local betterThanWait = (not bestUp)
                or (topCombat.cost <= bestUp.cost * 0.55 and bestUp.cost > curCash + estIncomeRate * 4)
                or (not bestUp.isEco and newTurretRoi >= (bestUp.rawRoi or bestUp.roi) * 0.85)
            local wantReplaceWeak = (#cellsNow == 0) and State.AutoReplaceWeak
                and (curCash >= topCombat.cost * 3 or curWave >= math.max(10, maxWave - 2))
            if needBaseTurrets or betterThanWait or wantReplaceWeak then
                if tryPlaceSmart(buildRf, topCombat, house, ownedTowers, combatCount, now, houseTowers) then return end
            end
        end

        -- 6.5) Scheduled Door Upgrade (runs AFTER Farms & Turret quota are met, strictly bounded by income/cash budget!)
        if needDoorTarget and dCost and curCash >= dCost then
            local affordableRatio = (dCost <= estIncomeRate * 5) or (dCost <= curCash * 0.35)
            local combatQuotaMet = (combatCount >= combatMinForDoor)
            if affordableRatio and combatQuotaMet then
                if fireDoorUpgrade(house, cash, 0) then return end
            end
        end

        -- 7) Upgrade highest-ROI tower
        if upRf and bestUp and curCash >= bestUp.cost then
            ensureNearWorldPos(bestUp.t:GetPivot().Position, true)
            recentUp[bestUp.t] = { level = bestUp.lvl, t = os.clock() }
            upRf:FireServer(bestUp.gx, bestUp.gz)
            return
        end

        -- 8) Late-game / Final-Wave Cash-Out & Full-Grid Smart Sell: convert dead Farms into Combat DPS + Door Armor (never loops!)
        if State.AutoReplaceWeak then
            local refundRf = tdRemote("StructRefund")
            local finalCashOut = (not inPvP and curWave >= math.max(10, maxWave - 1) and ((topROI and not topROI.isEco and topROI.cost > curCash) or (dCost and (blockedByDoor or lowestDoorLv < targetDoorLv) and dCost > curCash) or topCombat ~= nil))
            local canPlaceCombat = (topCombat ~= nil and curCash >= topCombat.cost)
            local allMaxed = (not bestUp and not blockedByDoor)
            local tightSpace = (#cellsNow == 0)
            local latePvPSell = inPvP and pvpWave >= 18
            if refundRf and (finalCashOut or (canPlaceCombat and (tightSpace or allMaxed or latePvPSell or lateEndgameSell))) and now - lastSellTick > 2.5 then
                local farms = {}
                for _, t in ipairs(ownedTowers) do
                    local tt = t:GetAttribute("TowerType")
                    if type(tt) == "string" and isIncome(tt) and tt ~= "MoneyMachine" then
                        farms[#farms + 1] = t
                    end
                end
                local minKeepFarms = (finalCashOut and 0) or (inPvP and 0) or (isTeamHouse and 2) or (lateEndgameSell and 5 or 6)
                if #farms > minKeepFarms then
                    table.sort(farms, function(a, b)
                        local la, lb = (a:GetAttribute("Level") or 1), (b:GetAttribute("Level") or 1)
                        if finalCashOut then return la > lb end
                        return la < lb
                    end)
                    local victim = farms[1]
                    local gx, gz = victim:GetAttribute("GridX"), victim:GetAttribute("GridZ")
                    if type(gx) == "number" and type(gz) == "number" then
                        ensureNearWorldPos(victim:GetPivot().Position, true)
                        lastSellTick = os.clock()
                        lastFarmSellTick = lastSellTick
                        refundRf:FireServer(gx, gz)
                        return
                    end
                end
            end
        end

        -- 9) Excess endgame cash -> push door armor even higher
        if bestUp == nil and topCombat == nil and topSupport == nil and not blockedByDoor then
            if dCost and curCash >= dCost then
                fireDoorUpgrade(house, cash, 0)
            end
        end
    end

    task.spawn(function()
        while Hub.alive do
            if State.AutoWin then
                local ok, err = pcall(stepAutoWin)
                if not ok then
                    warn("[TDHub] AutoWin step err:", err)
                end
            end
            task.wait(0.35)
        end
    end)

    -- Granular manual match loops (idle when AutoWin is ON)
    local lastUp = 0
    track(RunService.Heartbeat:Connect(function()
        if not (Hub.alive and State.AutoUpgrade) or State.AutoWin then return end
        tryLoadMatchModules()
        if not TowerConfig then return end
        local now = os.clock()
        if now - lastUp < State.UpgradeInterval then return end
        lastUp = now

        local house, cash, rf = myHouse(), cashValue(), tdRemote("StructRaise")
        local placed = workspace:FindFirstChild("PlacedTowers")
        if not (house and cash and rf and placed) then return end

        local okD, doorLevel = pcall(TowerConfig.GetDoorLevel, house)
        if not okD or type(doorLevel) ~= "number" then return end

        local cands = {}
        for _, t in ipairs(placed:GetChildren()) do
            if t:GetAttribute("OwnerUserId") == LocalPlayer.UserId and t:GetAttribute("HouseName") == house.Name then
                local gx, gz = t:GetAttribute("GridX"), t:GetAttribute("GridZ")
                local ttype, lvl = t:GetAttribute("TowerType"), t:GetAttribute("Level") or 1
                if type(gx) == "number" and type(gz) == "number" and type(ttype) == "string" and type(lvl) == "number" then
                    local capA = t:GetAttribute("LevelCap")
                    local okM, mx = pcall(TowerConfig.GetMaxLevel, ttype)
                    local cap = math.min(type(capA) == "number" and capA or math.huge, (okM and type(mx) == "number") and mx or math.huge)
                    if lvl < cap then
                        local okR, req = pcall(TowerConfig.GetRequiredDoorLevel, lvl + 1)
                        if okR and type(req) == "number" and req <= doorLevel then
                            local okC, cost = pcall(TowerConfig.GetUpgradeCost, ttype, lvl)
                            if okC and type(cost) == "number" and cash.Value - cost >= State.CashReserve then
                                local rec = recentUp[t]
                                if not rec or rec.level ~= lvl or now - rec.t > 1.5 then
                                    cands[#cands + 1] = { t = t, gx = gx, gz = gz, cost = cost, lvl = lvl, ttype = ttype }
                                end
                            end
                        end
                    end
                end
            end
        end
        if #cands == 0 then return end

        local order = State.UpgradeOrder
        table.sort(cands, function(a, b)
            if order == "Income towers first" then
                local ia, ib = isIncome(a.ttype), isIncome(b.ttype)
                if ia ~= ib then return ia end
            end
            if order == "Most expensive first" then return a.cost > b.cost end
            if order == "Lowest level first" then
                if a.lvl ~= b.lvl then return a.lvl < b.lvl end
            end
            return a.cost < b.cost
        end)

        local c = cands[1]
        recentUp[c.t] = { level = c.lvl, t = now }
        task.spawn(function()
            ensureNearWorldPos(c.t:GetPivot().Position, true)
            rf:FireServer(c.gx, c.gz)
        end)
    end))

    local lastBank = 0
    track(RunService.Heartbeat:Connect(function()
        if not (Hub.alive and (State.AutoBank or State.AutoGolemForge)) or State.AutoWin then return end
        tryLoadMatchModules()
        local now = os.clock()
        if now - lastBank < 1 then return end
        lastBank = now
        local house = myHouse()
        if house then drainAndForgeOwned(house, State.BankPct) end
    end))

    local lastDoor = 0
    track(RunService.Heartbeat:Connect(function()
        if not (Hub.alive and (State.AutoRepair or State.AutoDoorUp or State.AutoFree2X or State.AutoPlayAgain or State.AutoSpeed)) then return end
        local now = os.clock()
        if now - lastDoor < 1 then return end
        lastDoor = now
        tryLoadMatchModules()
        local house = myHouse()

        if State.AutoSpeed and workspace:GetAttribute("WaveOneStarted") == true and attr("MatchEndedEarly") ~= true and workspace:GetAttribute("ResolvedGameMode") ~= "PvP" then
            if now - lastSpeedFire >= 1.5 then
                local wantMult, okUse = resolveDesiredSpeed(State.SpeedTarget)
                local cur = getCurrentSpeedMultiplier()
                if okUse and cur ~= wantMult then
                    lastSpeedFire = now
                    applySpeedMultiplier(wantMult, false)
                end
            end
        end

        if State.AutoRepair and house and not State.AutoWin then
            fireRepairIfReady(house, State.RepairBelow)
        end
        if State.AutoDoorUp and house and TowerConfig and not State.AutoWin then
            fireDoorUpgrade(house, cashValue(), State.CashReserve)
        end
        if State.AutoFree2X and now > free2xGuard then
            local tokens = tonumber(attr("Free2X")) or 0
            if tokens >= 1 and attr("MatchRewardCoins") ~= nil and attr("MatchRewardDoubled") ~= true then
                local rf = ReplicatedStorage:FindFirstChild("UseFree2X")
                if rf then
                    free2xGuard = now + 10
                    task.spawn(function() pcall(function() return rf:InvokeServer() end) end)
                end
            end
        end
        if State.AutoPlayAgain then
            local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local endUi = pg and pg:FindFirstChild("EndScreenUI")
            local overlay = endUi and endUi:FindFirstChild("EndingScreenOverlay")
            local pvpEnd = pg and pg:FindFirstChild("PvPEndGui")
            local endVisible = (overlay and overlay.Visible == true) or (pvpEnd and pvpEnd.Enabled == true)
            if endVisible then
                if not playAgainVoted then
                    local rName = (type(PlayAgainConfig) == "table" and PlayAgainConfig.RemoteName) or "PlayAgain"
                    local rf = tdRemote(rName)
                    if rf then
                        playAgainVoted = true
                        rf:FireServer("vote", true)
                    end
                end
            else
                playAgainVoted = false
            end
        else
            playAgainVoted = false
        end
    end))

    local lastAutoPlace = 0
    track(RunService.Heartbeat:Connect(function()
        if not (Hub.alive and State.AutoPlace and State.PlaceType) or State.AutoWin then return end
        tryLoadMatchModules()
        if not TowerConfig then return end
        local now = os.clock()
        if now - lastAutoPlace < 1.2 then return end
        lastAutoPlace = now

        local house, cash, rf = myHouse(), cashValue(), tdRemote("BuildRequest")
        local placed = workspace:FindFirstChild("PlacedTowers")
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not (house and cash and rf and placed and hrp) then return end

        local typeName = State.PlaceType
        local okP, cost = pcall(TowerConfig.GetPlaceCost, typeName)
        if not okP or type(cost) ~= "number" or cash.Value - cost < State.CashReserve then return end

        local okL, limit = pcall(TowerConfig.GetPlacementLimit, typeName)
        local okN, have = pcall(TowerConfig.CountTowersPlacedBy, placed, house.Name, typeName, LocalPlayer.UserId)
        if okL and okN and type(limit) == "number" and type(have) == "number" and have >= limit then return end

        local cells = freeCellsDetailed(house)
        table.sort(cells, function(a, b)
            return (Vector3.new(a.world.X, hrp.Position.Y, a.world.Z) - hrp.Position).Magnitude
                < (Vector3.new(b.world.X, hrp.Position.Y, b.world.Z) - hrp.Position).Magnitude
        end)
        for _, c in ipairs(cells) do
            if now - (recentCell[c.key] or 0) > 4 then
                recentCell[c.key] = now
                task.spawn(function()
                    ensureNearWorldPos(c.world, true)
                    rf:FireServer(typeName, c.cx, c.cz)
                end)
                return
            end
        end
    end))
end

local function placeAtCharacter(typeName)
    tryLoadMatchModules()
    if not TowerConfig then return false, "ต้องอยู่ในด่าน (ยังไม่พบ TowerConfig)" end
    if not typeName then return false, "กรุณาเลือกป้อมก่อน" end
    local house, cash, rf = myHouse(), cashValue(), tdRemote("BuildRequest")
    local placed = workspace:FindFirstChild("PlacedTowers")
    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (house and cash and rf and placed and hrp) then return false, "ยังไม่พบบ้านของคุณหรือตัวละคร" end

    local okO, origin = pcall(TowerConfig.GetHouseGridOrigin, house)
    if not okO then return false, "ไม่สามารถอ่าน Grid Origin ได้" end
    local okW, cx, cz = pcall(TowerConfig.WorldToCell, hrp.Position, origin)
    if not okW or type(cx) ~= "number" or type(cz) ~= "number" then return false, "หาช่องวางไม่สำเร็จ" end

    local key = TowerConfig.HouseCellToKey(house.Name, cx, cz)
    for _, t in ipairs(placed:GetChildren()) do
        if t:GetAttribute("GridKey") == key then return false, "ช่อง " .. cx .. ", " .. cz .. " มีป้อมวางอยู่แล้ว" end
    end

    local okP, cost = pcall(TowerConfig.GetPlaceCost, typeName)
    if not okP or type(cost) ~= "number" then return false, "ไม่รู้จักประเภทป้อม: " .. tostring(typeName) end
    if cost > cash.Value then return false, "เงินไม่พอ (" .. cost .. ")" end

    local okL, limit = pcall(TowerConfig.GetPlacementLimit, typeName)
    local okN, have = pcall(TowerConfig.CountTowersPlacedBy, placed, house.Name, typeName, LocalPlayer.UserId)
    if okL and okN and type(limit) == "number" and type(have) == "number" and have >= limit then
        return false, "ถึงจำนวนสูงสุดแล้ว (" .. have .. "/" .. limit .. ")"
    end
    rf:FireServer(typeName, cx, cz)
    return true, "ส่งคำสั่งวาง " .. typeName .. " ที่ช่อง " .. cx .. ", " .. cz
end

-- ---------------------------------------------------------------- FluentStudio window & adapter
local isMobile = (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)
    or (type(FluentStudio.IsMobile) == "function" and FluentStudio.IsMobile())
    or false

local uiParent
local okCg, cg = pcall(function() return game:GetService("CoreGui") end)
if okCg and typeof(cg) == "Instance" then
    uiParent = cg
elseif type(gethui) == "function" then
    local okHui, huiInst = pcall(gethui)
    if okHui and typeof(huiInst) == "Instance" then uiParent = huiInst end
end

local rawWindow = FluentStudio.CreateWindow({
    Title = IS_MATCH and "TD Hub v2.3 [Match]" or "TD Hub v2.3 [Lobby]",
    SubTitle = isMobile and "แตะปุ่มลอยเพื่อเปิด" or nil,
    TabWidth = 148,
    Size = isMobile and UDim2.fromOffset(560, 380) or UDim2.fromOffset(650, 500),
    AcrylicBlur = false,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.Unknown,
    DisplayOrder = 999999,
    Parent = uiParent,
    Resizable = true,
    SearchBar = true,
    MobileToggleButton = isMobile,
})
if superseded() then
    pcall(function() rawWindow:Destroy() end)
    return
end
Hub.Window = rawWindow

ensureWindowVisible = function()
    if not Hub.alive then return end
    local sg = rawWindow.ScreenGui
    if sg then
        if uiParent and sg.Parent ~= uiParent then pcall(function() sg.Parent = uiParent end) end
        sg.Enabled = true
    end
    pcall(function() rawWindow:SetVisible(true) end)
end

local winGui = rawWindow.ScreenGui
if winGui then
    if uiParent and winGui.Parent ~= uiParent then
        pcall(function() winGui.Parent = uiParent end)
    end
    winGui.Enabled = true
    track(winGui:GetPropertyChangedSignal("Enabled"):Connect(function()
        if Hub.alive and not winGui.Enabled then winGui.Enabled = true end
    end))
    track(winGui:GetPropertyChangedSignal("Parent"):Connect(function()
        if Hub.alive and uiParent and winGui.Parent and winGui.Parent ~= uiParent then
            task.defer(function()
                if Hub.alive and winGui.Parent and winGui.Parent ~= uiParent then
                    pcall(function() winGui.Parent = uiParent end)
                end
            end)
        end
    end))
    local fb = winGui:FindFirstChild("FloatingToggle")
    if fb and fb:IsA("TextButton") then fb.BackgroundTransparency = 0.25 end
end

local activeToggleKey = isMobile and Enum.KeyCode.Unknown or CONFIG.ToggleKey
local function isRecordingKeybind()
    local gui = rawWindow.ScreenGui
    if not gui then return false end
    for _, d in ipairs(gui:GetDescendants()) do
        if d.Name == "KeybindButton" and d:IsA("TextButton") and d.Text == "..." then return true end
    end
    return false
end
track(UserInputService.InputBegan:Connect(function(input)
    if activeToggleKey == Enum.KeyCode.Unknown then return end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == activeToggleKey then
        local focused = UserInputService:GetFocusedTextBox()
        local gui = rawWindow.ScreenGui
        if not (focused and gui and focused:IsDescendantOf(gui)) and not isRecordingKeybind() then
            pcall(function() rawWindow:Toggle() end)
        end
    end
end))

local Options = {}
local function normalizeElementArgs(arg1, arg2)
    if type(arg1) == "string" then
        local opts = arg2 or {}
        opts.Id = arg1
        return arg1, opts
    end
    local opts = arg1 or {}
    return opts.Id, opts
end

local function wrapElement(elem, id)
    if not elem then return elem end
    if id and id ~= "" then Options[id] = elem end
    if elem.Type == "Slider" and type(elem.SetValue) == "function" then
        local origSet = elem.SetValue
        elem.SetValue = function(self, val, silent)
            local n = tonumber(val)
            if n == nil then return end
            return origSet(self, n, silent)
        end
    end
    if not elem.SetDesc and elem.SetDescription then
        elem.SetDesc = function(self, desc) return self:SetDescription(desc) end
    end
    if not elem.SetContent and elem.SetDescription then
        elem.SetContent = function(self, content) return self:SetDescription(content) end
    end
    return elem
end

local function wrapContainer(container)
    local wrapped = setmetatable({}, { __index = container })
    for _, method in ipairs({ "AddToggle", "AddSlider", "AddButton", "AddParagraph", "AddKeybind", "AddColorpicker", "AddInput" }) do
        wrapped[method] = function(_, arg1, arg2)
            local id, opts = normalizeElementArgs(arg1, arg2)
            if method == "AddKeybind" and isMobile and id == "MenuKeybind" then opts.Visible = false end
            return wrapElement(container[method](container, opts), id)
        end
    end
    function wrapped:AddDropdown(arg1, arg2)
        local id, opts = normalizeElementArgs(arg1, arg2)
        if type(opts.Default) == "number" and opts.Values and opts.Values[opts.Default] then
            opts.Default = opts.Values[opts.Default]
        end
        return wrapElement(container:AddDropdown(opts), id)
    end
    function wrapped:AddSection(arg1)
        local opts = type(arg1) == "string" and { Title = arg1, Collapsible = false, DefaultOpen = true } or (arg1 or {})
        return wrapContainer(container:AddSection(opts))
    end
    return wrapped
end

local Fluent = {
    Version = FluentStudio.Version or "1.0.0",
    Options = Options,
    Themes = (type(FluentStudio.GetThemes) == "function" and FluentStudio.GetThemes()) or { "Dark", "Light", "Amethyst", "Aqua", "Rose" },
    UseAcrylic = false,
    Transparency = false,
    MinimizeKey = CONFIG.ToggleKey,
    Unloaded = false,
    Notify = function(_, opts) return rawWindow:Notify(opts) end,
    SetTheme = function(_, name) pcall(function() rawWindow:SetTheme(name) end) end,
    ToggleAcrylic = function(_, on) pcall(function() rawWindow:SetAcrylicBlur(on) end) end,
    ToggleTransparency = function() end,
    Destroy = function(self)
        self.Unloaded = true
        pcall(function() rawWindow:Destroy() end)
    end,
}
Hub.Fluent = Fluent

local function notify(title, content, duration)
    pcall(function() rawWindow:Notify({ Title = title, Content = content, Duration = duration or 4 }) end)
end

local function addTabSafe(title, icon)
    local ok, tab = pcall(function() return rawWindow:AddTab({ Title = title, Icon = icon }) end)
    if not (ok and tab) then tab = rawWindow:AddTab({ Title = title }) end
    return wrapContainer(tab)
end

-- ---------------------------------------------------------------- DYNAMIC UI BY PLACE (LOBBY vs MATCH)
local TabSettings

if IS_LOBBY then
    -- ================= LOBBY-ONLY UI =================
    local TabInfo = addTabSafe("สถานะ Lobby", "info")
    local TabLobby = addTabSafe("จัดป้อม & อัปเกรด", "crown")
    local TabPets = addTabSafe("สัตว์เลี้ยง (Pets)", "heart")
    local TabChests = addTabSafe("สุ่มกล่อง & รางวัล", "gift")
    local TabMisc = addTabSafe("เครื่องมือ", "wrench")
    TabSettings = addTabSafe("ตั้งค่า", "settings")

    local secOverview = TabInfo:AddSection({ Title = "ข้อมูลบัญชี & สถิติ", Collapsible = false })
    paraOverview = secOverview:AddParagraph({ Title = "ภาพรวม", Content = "กำลังโหลด..." })
    local secOwned = TabInfo:AddSection({ Title = "ป้อมที่มีในคลัง (วิเคราะห์ความคุ้ม)", Collapsible = false })
    paraTelemetry = secOwned:AddParagraph({ Title = "คลังป้อม & ชุดแนะนำ", Content = "กำลังโหลด..." })

    local secLoadout = TabLobby:AddSection({ Title = "จัดชุดป้อมที่ดีที่สุด (Loadout Optimizer)", Collapsible = false })
    secLoadout:AddDropdown({
        Id = "LoadoutPreset",
        Title = "เลือกแนวทางจัดป้อมจากคลัง",
        Values = {
            "ดีที่สุดจากคลัง (ปั๊มเงิน+แรง+ถูก)",
            "ปั๊มเงิน + AoE + บัฟ (ชนะโหมดยาก)",
            "ปั๊มเงินจัดเต็ม + กัน 1 ป้อม",
            "ตีถูก & เคลียร์ไว (เน้นดาเมจ)",
        },
        Default = State.LoadoutPreset,
        Callback = function(v) setState("LoadoutPreset", v) end,
    })
    secLoadout:AddButton({
        Title = "จัด Loadout อัตโนมัติเดี๋ยวนี้ (SetEquipped)",
        Description = "วิเคราะห์คลังจริง (เช่น MiningCaveFarm 26 หลัง + Flamethrower 17 ป้อม + Missile 10 ป้อม + MilitaryBase บัฟ) แล้วกดใส่ให้ทันที",
        ButtonText = "ใส่ป้อมแนะนำ",
        Callback = function()
            task.spawn(function()
                local target = computeBestOwnedLoadout(State.LoadoutPreset)
                local ok, msg = applyLoadoutViaRemote(target)
                notify("จัด Loadout", msg, ok and 4 or 5)
            end)
        end,
    })

    -- Auto-equip optimal Solo Hard / AutoWin loadout on Lobby load if current loadout only has 1 combat tower
    task.spawn(function()
        task.wait(1.2)
        if not (Hub.alive and IS_LOBBY and State.AutoWin) then return end
        local target = computeBestOwnedLoadout(State.LoadoutPreset)
        local cur = loadoutTypes()
        local curStr = table.concat(cur, ",")
        local tarStr = table.concat(target, ",")
        if #target >= 3 and curStr ~= tarStr then
            local ok, msg = applyLoadoutViaRemote(target)
            if ok then
                notify("จัดชุดชนะโหมดยากอัตโนมัติ", msg, 5)
            end
        end
    end)

    -- Upgrade Owned Towers in Lobby (UpgradeTower:InvokeServer(towerName))
    local upLabelToName, ddLobbyUpgrade = {}, nil
    local selectedUpLabel = nil
    local function scanUpgradableTowers()
        table.clear(upLabelToName)
        local tmt = ReplicatedStorage:FindFirstChild("TowerModelTemplates")
        local owned = getOwnedTowers()
        local list = {}
        for tName, info in pairs(owned) do
            local tpl = tmt and tmt:FindFirstChild(tName)
            local absMax = tpl and tonumber(tpl:GetAttribute("MaxLevel")) or info.maxOwned
            if info.maxOwned < absMax then
                local nextCost = tpl and tonumber(tpl:GetAttribute("UpgradeCost" .. (info.maxOwned + 1))) or nil
                local costStr = nextCost and (tostring(nextCost) .. " Coins") or "Max"
                local lbl = string.format("%s | Lv.%d/%d (%s)", tName, info.maxOwned, absMax, costStr)
                upLabelToName[lbl] = tName
                list[#list + 1] = lbl
            end
        end
        table.sort(list)
        if #list == 0 then list[1] = "(ทุกป้อมเลเวลสูงสุดแล้ว)" end
        return list
    end
    local initUpList = scanUpgradableTowers()
    selectedUpLabel = initUpList[1]

    local secLobbyUp = TabLobby:AddSection({ Title = "อัปเกรดเลเวลป้อมในคลังด้วย Coins (ปลดล็อกเลเวลในด่าน)", Collapsible = false })
    ddLobbyUpgrade = secLobbyUp:AddDropdown({
        Id = "LobbyUpgradeTower",
        Title = "เลือกป้อมที่ต้องการอัปเกรด",
        Values = initUpList,
        Default = initUpList[1],
        Callback = function(v) selectedUpLabel = v end,
    })
    secLobbyUp:AddButton({
        Title = "อัปเกรดป้อมที่เลือก 1 ขั้น (UpgradeTower)",
        ButtonText = "อัปเกรด",
        Callback = function()
            local tName = upLabelToName[selectedUpLabel]
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("UpgradeTower")
            if not (rf and tName) then
                notify("อัปเกรดป้อม", "ไม่มีป้อมที่อัปเกรดได้หรือยังไม่ได้เลือก", 3)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer(tName) end)
                local msg = ok and (type(res) == "table" and (res.ok and ("อัปเกรด " .. tName .. " สำเร็จ!") or tostring(res.err or res.reason)) or tostring(res)) or tostring(res)
                notify("อัปเกรดป้อม", msg, 4)
                local fresh = scanUpgradableTowers()
                selectedUpLabel = fresh[1]
                task.spawn(function()
                    if ddLobbyUpgrade and ddLobbyUpgrade.SetValues then pcall(function() ddLobbyUpgrade:SetValues(fresh) end) end
                    if ddLobbyUpgrade and ddLobbyUpgrade.SetValue then pcall(function() ddLobbyUpgrade:SetValue(fresh[1], true) end) end
                end)
            end)
        end,
    })
    secLobbyUp:AddButton({
        Title = "รีเฟรชรายการอัปเกรดป้อม",
        ButtonText = "รีเฟรช",
        Callback = function()
            local fresh = scanUpgradableTowers()
            selectedUpLabel = fresh[1]
            task.spawn(function()
                if ddLobbyUpgrade and ddLobbyUpgrade.SetValues then pcall(function() ddLobbyUpgrade:SetValues(fresh) end) end
                if ddLobbyUpgrade and ddLobbyUpgrade.SetValue then pcall(function() ddLobbyUpgrade:SetValue(fresh[1], true) end) end
            end)
            notify("อัปเกรดป้อม", "รีเฟรชรายการแล้ว (" .. #fresh .. " รายการ)", 2)
        end,
    })

    local secPvPLobby = TabLobby:AddSection({ Title = "เข้าคิวโหมด PvP ด่วน & ตั้งค่า PvP AI", Collapsible = false })
    secPvPLobby:AddToggle({
        Id = "LobbyAutoPvPDraft",
        Title = "เปิด Auto Ban & Pick อัตโนมัติเมื่อเข้าแมตช์ PvP",
        Default = State.AutoPvPDraft,
        Callback = function(v) setState("AutoPvPDraft", v == true) end,
    })
    secPvPLobby:AddDropdown({
        Id = "LobbyPvPBanStyle",
        Title = "กลยุทธ์การแบน (Ban Priority)",
        Values = { "แบนตัวเมต้า (เว้นตัวเก่งของเรา)", "แบนตัวเมต้าสูงสุด (ทุกตัว)" },
        Default = State.PvPBanStyle,
        Callback = function(v) setState("PvPBanStyle", v) end,
    })
    secPvPLobby:AddDropdown({
        Id = "LobbyPvPCustomBans",
        Title = "รายการตัวที่จะแบนก่อน (Custom Ban Targets)",
        Values = PVP_BAN_CHOICES,
        Multi = true,
        Default = (parseCsvList(State.PvPCustomBans)),
        Callback = function(v)
            local arr = parseCsvList(v)
            setState("PvPCustomBans", table.concat(arr, ","))
        end,
    })
    secPvPLobby:AddDropdown({
        Id = "LobbyPvPSendMode",
        Title = "กลยุทธ์ส่งซอมบี้ PvP (Auto Send)",
        Values = { "สมดุล Eco + Rush ชนะไว", "ปั๊ม Eco เน้นรายได้", "สาย Rush ถล่มประตูไว", "ปิด (ไม่ส่งมอน)" },
        Default = State.PvPSendMode,
        Callback = function(v) setState("PvPSendMode", v) end,
    })
    secPvPLobby:AddToggle({
        Id = "LobbyAutoDoorTargetUp",
        Title = "อัปเกรดประตูตามแผนอัตโนมัติเมื่อเข้าแมตช์",
        Default = State.AutoDoorTargetUp,
        Callback = function(v) setState("AutoDoorTargetUp", v == true) end,
    })
    secPvPLobby:AddDropdown({
        Id = "LobbyAutoAcceptTeamUp",
        Title = "รับคำขอเข้าทีม/ปุ่มเดียวกันอัตโนมัติ",
        Values = { "ปิด", "เฉพาะเพื่อน (Friends)", "ทุกคน" },
        Default = State.AutoAcceptTeamUp,
        Callback = function(v) setState("AutoAcceptTeamUp", v) end,
    })
    local function queuePvPFromLobby(fmt, ranked)
        local pqr = ReplicatedStorage:FindFirstChild("PvPQueueRemotes")
        local qEv = pqr and pqr:FindFirstChild("PvPQueue")
        if not qEv then
            notify("PvP Queue", "ไม่พบ PvPQueueRemotes.PvPQueue", 4)
            return
        end
        qEv:FireServer("Join", { Format = fmt, Ranked = ranked })
        notify("PvP Queue", string.format("เข้าคิว PvP %s (%s) แล้ว! เมื่อเข้าด่าน AI จะแบน/เลือก/เล่นให้อัตโนมัติ", fmt, ranked and "Ranked" or "Casual"), 4)
    end
    secPvPLobby:AddButton({
        Title = "เข้าคิว PvP 1v1 Ranked (ได้แต้มแรงค์ + เหรียญรางวัลสูงสุด)",
        ButtonText = "1v1 Ranked",
        Callback = function() queuePvPFromLobby("1v1", true) end,
    })
    secPvPLobby:AddButton({
        Title = "เข้าคิว PvP 1v1 Casual (ซ้อมมือไม่เสียแรงค์)",
        ButtonText = "1v1 Casual",
        Callback = function() queuePvPFromLobby("1v1", false) end,
    })
    secPvPLobby:AddButton({
        Title = "เข้าคิว PvP 2v2 Ranked",
        ButtonText = "2v2 Ranked",
        Callback = function() queuePvPFromLobby("2v2", true) end,
    })
    secPvPLobby:AddButton({
        Title = "ยกเลิกคิว PvP (Leave Queue)",
        ButtonText = "ออกคิว",
        Callback = function()
            local pqr = ReplicatedStorage:FindFirstChild("PvPQueueRemotes")
            local qEv = pqr and pqr:FindFirstChild("PvPQueue")
            if qEv then
                qEv:FireServer("Leave")
                notify("PvP Queue", "ยกเลิกคิว PvP แล้ว", 3)
            end
        end,
    })

    -- Pet System in Lobby (Inventory + Equip + UpgradePet + OpenCrate)
    local PetCfg = nil
    task.spawn(function()
        local pcMod = ReplicatedStorage:FindFirstChild("PetCratesConfig")
        if pcMod and pcMod:IsA("ModuleScript") then pcall(function() PetCfg = require(pcMod) end) end
    end)

    local petLabelToName, ddPets = {}, nil
    local selectedPetLabel = nil
    local function scanOwnedPets()
        table.clear(petLabelToName)
        local list, descLines = {}, {}
        local maxLv = (PetCfg and PetCfg.MAX_PET_LEVEL) or 5
        for k, v in pairs(LocalPlayer:GetAttributes()) do
            if type(v) == "number" and v > 0 then
                local pName = tostring(k):match("^TowerMax_Pet_(.+)$")
                if pName then
                    local rar = (PetCfg and PetCfg.PET_RARITY and PetCfg.PET_RARITY[pName]) or "Rare"
                    local costs = PetCfg and PetCfg.UPGRADE_COSTS and PetCfg.UPGRADE_COSTS[rar]
                    local nextCost = (v < maxLv and costs and costs[v]) or nil
                    local costStr = nextCost and (tostring(nextCost) .. " Coins") or "MAX"
                    local lbl = string.format("%s (%s) | Lv.%d/%d (%s)", pName, rar, v, maxLv, costStr)
                    petLabelToName[lbl] = pName
                    list[#list + 1] = lbl
                    local rawDesc = PetCfg and PetCfg.PET_DESCRIPTIONS and PetCfg.PET_DESCRIPTIONS[pName]
                    if type(rawDesc) == "string" then
                        local cleanDesc = rawDesc:gsub("<[^>]+>", "")
                        descLines[#descLines + 1] = string.format("• %s Lv.%d (%s): %s", pName, v, rar, cleanDesc)
                    end
                end
            end
        end
        table.sort(list)
        if #list == 0 then list[1] = "(ยังไม่มีสัตว์เลี้ยง - เปิดสุ่มด้านล่างด้วย Gems)" end
        return list, table.concat(descLines, "\n")
    end

    local initPetList, initPetDesc = scanOwnedPets()
    selectedPetLabel = initPetList[1]

    local secPetOwn = TabPets:AddSection({ Title = "สัตว์เลี้ยงในคลัง (สวมใส่ & อัปเกรด)", Collapsible = false })
    local paraPetDesc = secPetOwn:AddParagraph({ Title = "สกิลสัตว์เลี้ยงของคุณ", Content = (#initPetDesc > 0) and initPetDesc or "ยังไม่มีสัตว์เลี้ยง (แนะนำ Bunny/Dragon ซ่อมประตูอัตโนมัติ หรือ Deer บัฟดาเมจ)" })
    ddPets = secPetOwn:AddDropdown({
        Id = "LobbyPetSelect",
        Title = "เลือกสัตว์เลี้ยง",
        Values = initPetList,
        Default = initPetList[1],
        Callback = function(v) selectedPetLabel = v end,
    })
    local function refreshPetUI()
        local fresh, desc = scanOwnedPets()
        selectedPetLabel = fresh[1]
        task.spawn(function()
            if ddPets and ddPets.SetValues then pcall(function() ddPets:SetValues(fresh) end) end
            if ddPets and ddPets.SetValue then pcall(function() ddPets:SetValue(fresh[1], true) end) end
            if paraPetDesc and paraPetDesc.SetContent then
                pcall(function() paraPetDesc:SetContent((#desc > 0) and desc or "ยังไม่มีสัตว์เลี้ยง") end)
            end
        end)
    end
    secPetOwn:AddButton({
        Title = "สวมใส่สัตว์เลี้ยงที่เลือก (Equip Pet)",
        Description = "หมายเหตุ: ใช้ช่องเดียวกับ Loadout (SetEquipped 'Pet_<ชื่อ>')",
        ButtonText = "ใส่สัตว์เลี้ยง",
        Callback = function()
            local pName = petLabelToName[selectedPetLabel]
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("SetEquipped")
            if not (rf and pName) then
                notify("สัตว์เลี้ยง", "กรุณาเลือกสัตว์เลี้ยงที่มีในคลังก่อน", 3)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer("Pet_" .. pName, true) end)
                local msg = ok and (type(res) == "table" and (res.ok and ("สวมใส่ Pet_" .. pName .. " แล้ว!") or tostring(res.err or res.reason)) or tostring(res)) or tostring(res)
                notify("สัตว์เลี้ยง", msg, 4)
            end)
        end,
    })
    secPetOwn:AddButton({
        Title = "ถอดสัตว์เลี้ยงที่เลือก (Unequip Pet)",
        ButtonText = "ถอด",
        Callback = function()
            local pName = petLabelToName[selectedPetLabel]
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("SetEquipped")
            if not (rf and pName) then return end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer("Pet_" .. pName, false) end)
                notify("สัตว์เลี้ยง", ok and "ถอดสัตว์เลี้ยงแล้ว" or tostring(res), 3)
            end)
        end,
    })
    secPetOwn:AddButton({
        Title = "อัปเกรดสัตว์เลี้ยงที่เลือก 1 ขั้น (UpgradePet ด้วย Coins)",
        ButtonText = "อัปเกรด Pet",
        Callback = function()
            local pName = petLabelToName[selectedPetLabel]
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("UpgradePet")
            if not (rf and pName) then
                notify("อัปเกรด Pet", "กรุณาเลือกสัตว์เลี้ยงที่มีในคลังก่อน", 3)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer(pName) end)
                local msg = ok and (type(res) == "table" and (res.ok and ("อัปเกรด " .. pName .. " สำเร็จ!") or tostring(res.err or res.reason)) or tostring(res)) or tostring(res)
                notify("อัปเกรด Pet", msg, 4)
                refreshPetUI()
            end)
        end,
    })
    secPetOwn:AddButton({
        Title = "รีเฟรชรายการสัตว์เลี้ยง",
        ButtonText = "รีเฟรช",
        Callback = function()
            refreshPetUI()
            notify("สัตว์เลี้ยง", "อัปเดตรายการในคลังแล้ว", 2)
        end,
    })

    local petCrateChoice = "Mythic Pet | 100 Gems"
    local petCrateCount = 1
    local petCrateIdMap = {
        ["Rare Pet | 5 Gems"] = "Rare",
        ["Epic Pet | 50 Gems"] = "Epic",
        ["Mythic Pet | 100 Gems"] = "Mythic",
        ["Legendary Pet | 250 Gems"] = "Legendary",
        ["Divine Egg | 2,500 Gems"] = "DivineShop",
    }
    local function formatDropResultList(items, nameField)
        if type(items) ~= "table" or #items == 0 then return nil end
        local parts = {}
        for _, item in ipairs(items) do
            if type(item) == "table" then
                local nm = item[nameField] or item.id or item.name or "?"
                local rar = item.rarity and ("[" .. tostring(item.rarity) .. "]") or ""
                local pityTag = item.pity and " (PITY!)" or ""
                parts[#parts + 1] = tostring(nm) .. rar .. pityTag
            else
                parts[#parts + 1] = tostring(item)
            end
        end
        return table.concat(parts, ", ")
    end

    getPetInfoText = function()
        if not PetCfg then
            local pcMod = ReplicatedStorage:FindFirstChild("PetCratesConfig")
            if pcMod and pcMod:IsA("ModuleScript") then pcall(function() PetCfg = require(pcMod) end) end
        end
        local cid = petCrateIdMap[petCrateChoice] or "Mythic"
        local leg = math.floor(num(attr("LegendaryPityEgg")))
        local legLim = math.max(1, math.floor(num(attr("LegendaryPityEggLimit")) or 20))
        local div = math.floor(num(attr("DivinePityEgg")))
        local divLim = math.max(1, math.floor(num(attr("DivinePityEggLimit")) or 30))
        local chancesStr = ""
        if PetCfg and type(PetCfg.chances) == "function" then
            local okC, ch = pcall(PetCfg.chances, cid)
            if okC and type(ch) == "table" then
                local parts = {}
                for _, rar in ipairs({ "Common", "Rare", "Epic", "Mythic", "Legendary", "Divine" }) do
                    local pct = ch[rar]
                    if type(pct) == "number" and pct > 0 then
                        parts[#parts + 1] = string.format("%s %.2f%%", rar, pct)
                    end
                end
                if #parts > 0 then chancesStr = "\nเรท " .. cid .. ": " .. table.concat(parts, " | ") end
            end
        end
        return string.format(
            "Pity ไข่ Legendary: %d/%d (เหลือ %d ฟอง)\nPity ไข่ Divine: %d/%d (เหลือ %d ฟอง)%s\n*เรทสุ่มคำนวณฝั่งเซิร์ฟเวอร์ (ตัวนับ Pity ช่วยบอกจังหวะการันตี)",
            leg, legLim, math.max(1, legLim - leg),
            div, divLim, math.max(1, divLim - div),
            chancesStr
        )
    end

    local secPetCrate = TabPets:AddSection({ Title = "เปิดกล่องสุ่มสัตว์เลี้ยงระยะไกล (OpenCrate ใช้ Gems)", Collapsible = false })
    paraPetInfo = secPetCrate:AddParagraph({ Title = "เรทไข่ & ตัวนับการันตี (Pity)", Content = "กำลังโหลดข้อมูล..." })
    task.spawn(function() setParaSafe(paraPetInfo, getPetInfoText()) end)
    secPetCrate:AddDropdown({
        Id = "PetCrateChoice",
        Title = "เลือกกล่องสัตว์เลี้ยง (แนะนำ Bunny/Dragon/Horse ช่วยซ่อมประตูอัตโนมัติ)",
        Values = { "Rare Pet | 5 Gems", "Epic Pet | 50 Gems", "Mythic Pet | 100 Gems", "Legendary Pet | 250 Gems", "Divine Egg | 2,500 Gems" },
        Default = petCrateChoice,
        Callback = function(v)
            petCrateChoice = v
            task.spawn(function() setParaSafe(paraPetInfo, getPetInfoText()) end)
        end,
    })
    secPetCrate:AddDropdown({
        Id = "PetCrateCount",
        Title = "จำนวนที่เปิด",
        Values = { "1 กล่อง", "10 กล่อง" },
        Default = "1 กล่อง",
        Callback = function(v) petCrateCount = (v == "10 กล่อง") and 10 or 1 end,
    })
    secPetCrate:AddButton({
        Title = "เปิดกล่องสัตว์เลี้ยงทันที",
        Description = "Bunny (Mythic): ซ่อมประตูทุกวินาที | Dragon (Legendary): ยิงแล้วซ่อมประตู | Deer: บัฟแรงขึ้นเมื่อประตู <50%",
        ButtonText = "เปิดกล่อง Pet",
        Callback = function()
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("OpenCrate")
            local cid = petCrateIdMap[petCrateChoice] or "Mythic"
            if not rf then
                notify("OpenCrate", "ไม่พบ Remotes.OpenCrate", 4)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer(cid, petCrateCount) end)
                if ok and type(res) == "table" then
                    if res.ok == false then
                        notify("เปิดกล่อง Pet ล้มเหลว", tostring(res.err or res.reason or "ไม่สำเร็จ"), 4)
                    else
                        local won = formatDropResultList(res.pets, "pet")
                            or (res.pet and (tostring(res.pet) .. (res.rarity and (" [" .. tostring(res.rarity) .. "]") or "")))
                            or "สำเร็จ!"
                        notify("เปิดกล่อง " .. cid, "ผลลัพธ์: " .. tostring(won), 5)
                        task.wait(0.3)
                        refreshPetUI()
                        if paraPetInfo and getPetInfoText then pcall(function() paraPetInfo:SetContent(getPetInfoText()) end) end
                    end
                else
                    notify("เปิดกล่อง " .. cid, ok and tostring(res) or ("Error: " .. tostring(res)), 4)
                end
            end)
        end,
    })

    -- Remote Chest Opener in Lobby (RollChest:InvokeServer(chestId, count))
    local ChestCfg = nil
    task.spawn(function()
        local scMod = ReplicatedStorage:FindFirstChild("ShopChestsConfig")
        if scMod and scMod:IsA("ModuleScript") then pcall(function() ChestCfg = require(scMod) end) end
    end)

    local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3, Mythic = 4, Legendary = 5, Divine = 6 }
    local chestChoice = "Mythic | 4,000 Coins"
    local chestCount = 1
    local chestStopTarget = "หยุดเมื่อได้ Legendary+"
    local smartRolling = false
    local chestIdMap = {
        ["Common | 150 Coins"] = "Common",
        ["Rare | 750 Coins"] = "Rare",
        ["Epic | 1,900 Coins"] = "Epic",
        ["Mythic | 4,000 Coins"] = "Mythic",
        ["Legendary | 7,500 Coins"] = "Legendary",
        ["Divine | 75,000 Coins"] = "DivineShop",
    }

    local function chestHitsTarget(res, targetLabel)
        if type(res) ~= "table" then return false end
        local needRank = 5
        if string.find(targetLabel, "Divine", 1, true) then
            needRank = 6
        elseif string.find(targetLabel, "Legendary", 1, true) then
            needRank = 5
        elseif string.find(targetLabel, "Mythic", 1, true) then
            needRank = 4
        end
        local items = (type(res.towers) == "table" and #res.towers > 0) and res.towers or { res }
        for _, it in ipairs(items) do
            if type(it) == "table" then
                if string.find(targetLabel, "Pity", 1, true) and it.pity then return true end
                local r = RARITY_RANK[tostring(it.rarity or "")] or 0
                if r >= needRank then return true end
            end
        end
        return false
    end

    getChestInfoText = function()
        if not ChestCfg then
            local scMod = ReplicatedStorage:FindFirstChild("ShopChestsConfig")
            if scMod and scMod:IsA("ModuleScript") then pcall(function() ChestCfg = require(scMod) end) end
        end
        local cid = chestIdMap[chestChoice] or "Mythic"
        local leg = math.floor(num(attr("LegendaryPityChest")))
        local legLim = math.max(1, math.floor(num(attr("LegendaryPityChestLimit")) or 20))
        local div = math.floor(num(attr("DivinePityChest")))
        local divLim = math.max(1, math.floor(num(attr("DivinePityChestLimit")) or 20))
        local tierStr = ""
        if ChestCfg and type(ChestCfg.Chests) == "table" then
            for _, c in ipairs(ChestCfg.Chests) do
                if c.id == cid and type(c.tiers) == "table" then
                    local parts = {}
                    for _, rar in ipairs({ "Rare", "Epic", "Mythic", "Legendary", "Divine" }) do
                        local pct = c.tiers[rar]
                        if type(pct) == "number" and pct > 0 then
                            parts[#parts + 1] = string.format("%s %.2g%%", rar, pct)
                        end
                    end
                    tierStr = "\nเรทกล่อง " .. cid .. ": " .. table.concat(parts, " | ")
                    break
                end
            end
        end
        return string.format(
            "Pity Legendary Chest: %d/%d (เหลือ %d กล่อง)\nPity Divine Chest: %d/%d (เหลือ %d กล่อง)%s\n*สุ่มจริงบนเซิร์ฟเวอร์ — Legendary นับ Pity20 | DivineShop นับ Divine Pity20",
            leg, legLim, math.max(1, legLim - leg),
            div, divLim, math.max(1, divLim - div),
            tierStr
        )
    end

    local secChests = TabChests:AddSection({ Title = "เปิดกล่องสุ่มป้อมจากระยะไกล (RollChest)", Collapsible = false })
    paraChestInfo = secChests:AddParagraph({ Title = "เรทกล่อง & ตัวนับการันตี (Pity)", Content = "กำลังโหลดข้อมูล..." })
    task.spawn(function() setParaSafe(paraChestInfo, getChestInfoText()) end)
    secChests:AddDropdown({
        Id = "ChestChoice",
        Title = "เลือกกล่องสุ่มป้อม",
        Values = { "Common | 150 Coins", "Rare | 750 Coins", "Epic | 1,900 Coins", "Mythic | 4,000 Coins", "Legendary | 7,500 Coins", "Divine | 75,000 Coins" },
        Default = chestChoice,
        Callback = function(v)
            chestChoice = v
            task.spawn(function() setParaSafe(paraChestInfo, getChestInfoText()) end)
        end,
    })
    secChests:AddDropdown({
        Id = "ChestCount",
        Title = "จำนวนที่เปิดต่อครั้ง",
        Values = { "1 กล่อง", "10 กล่อง" },
        Default = "1 กล่อง",
        Callback = function(v) chestCount = (v == "10 กล่อง") and 10 or 1 end,
    })
    secChests:AddButton({
        Title = "เปิดกล่องสุ่มป้อมทันที",
        Description = "ไม่ต้องเดินไปหน้าร้านค้า ใช้ Coins จริงเปิดกล่องที่เลือกได้เลย",
        ButtonText = "เปิดกล่อง",
        Callback = function()
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("RollChest")
            local cid = chestIdMap[chestChoice] or "Mythic"
            if not rf then
                notify("RollChest", "ไม่พบ Remotes.RollChest", 4)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer(cid, chestCount) end)
                if ok and type(res) == "table" then
                    if res.ok == false then
                        notify("เปิดกล่องล้มเหลว", tostring(res.err or res.reason or "ไม่สำเร็จ"), 4)
                    else
                        local won = formatDropResultList(res.towers, "tower")
                            or (res.tower and (tostring(res.tower) .. (res.rarity and (" [" .. tostring(res.rarity) .. "]") or "")))
                            or "สำเร็จ!"
                        notify("เปิดกล่อง " .. cid, "ผลลัพธ์: " .. tostring(won), 5)
                        if paraChestInfo and getChestInfoText then pcall(function() paraChestInfo:SetContent(getChestInfoText()) end) end
                    end
                else
                    notify("เปิดกล่อง " .. cid, ok and tostring(res) or ("Error: " .. tostring(res)), 4)
                end
            end)
        end,
    })
    secChests:AddDropdown({
        Id = "ChestStopTarget",
        Title = "เงื่อนไขหยุด (สำหรับโหมดสุ่มอัตโนมัติ)",
        Values = { "หยุดเมื่อได้ Mythic+", "หยุดเมื่อได้ Legendary+", "หยุดเมื่อได้ Divine", "หยุดเมื่อถึง Pity" },
        Default = chestStopTarget,
        Callback = function(v) chestStopTarget = v end,
    })
    secChests:AddToggle({
        Id = "AutoSmartRoll",
        Title = "สุ่มต่อเนื่องจนกว่าจะได้ระดับที่เลือก (หยุดทันทีที่ออกของดี)",
        Description = "ใช้ Coins เปิดทีละรอบอัตโนมัติและหยุดทันทีที่ได้ Mythic/Legendary/Divine หรือ Coins หมด",
        Default = false,
        Callback = function(v)
            smartRolling = (v == true)
            if not smartRolling then return end
            task.spawn(function()
                local rem = ReplicatedStorage:FindFirstChild("Remotes")
                local rf = rem and rem:FindFirstChild("RollChest")
                if not rf then
                    notify("Smart Roll", "ไม่พบ Remotes.RollChest", 4)
                    smartRolling = false
                    return
                end
                local rolls = 0
                while Hub.alive and IS_LOBBY and smartRolling do
                    local cid = chestIdMap[chestChoice] or "Mythic"
                    local ok, res = pcall(function() return rf:InvokeServer(cid, chestCount) end)
                    if not ok or type(res) ~= "table" or res.ok == false then
                        notify("Smart Roll หยุดแล้ว", (type(res) == "table" and tostring(res.err or res.reason)) or "Coins ไม่พอ/ล้มเหลว", 4)
                        smartRolling = false
                        break
                    end
                    rolls += 1
                    local won = formatDropResultList(res.towers, "tower") or tostring(res.tower or "?")
                    if chestHitsTarget(res, chestStopTarget) then
                        notify("Smart Roll ได้ของดีแล้ว!", string.format("(%d รอบ) %s", rolls, tostring(won)), 6)
                        smartRolling = false
                        break
                    end
                    task.wait(0.5)
                end
                local opt = Options and Options.AutoSmartRoll
                if opt and type(opt.SetValue) == "function" then pcall(function() opt:SetValue(false, true) end) end
                if paraChestInfo and getChestInfoText then pcall(function() paraChestInfo:SetContent(getChestInfoText()) end) end
            end)
        end,
    })

    local secRewards = TabChests:AddSection({ Title = "รางวัลรายวัน & โค้ดฟรีในหน้า Lobby", Collapsible = false })
    secRewards:AddButton({
        Title = "รับรางวัลรายวัน (DailyRewardClaim)",
        ButtonText = "รับ Daily",
        Callback = function()
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("DailyRewardClaim")
            if not rf then
                notify("Daily Reward", "ไม่พบ DailyRewardClaim", 4)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer() end)
                notify("Daily Reward", ok and ("ผลลัพธ์: " .. tostring(type(res) == "table" and (res.ok and "รับสำเร็จ!" or (res.reason or res.err or "ยังไม่ถึงเวลา")) or res)) or ("ล้มเหลว: " .. tostring(res)), 4)
            end)
        end,
    })
    secRewards:AddButton({
        Title = "รับรางวัลกลุ่ม / โซเชียล (+100 Cash เริ่มเกม)",
        ButtonText = "รับ Social",
        Callback = function()
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("ClaimSocialReward")
            if not rf then
                notify("Social Reward", "ไม่พบ ClaimSocialReward", 4)
                return
            end
            if attr("SocialRewardClaimed") == true then
                notify("Social Reward", "รับรางวัลไปแล้ว", 3)
                return
            end
            task.spawn(function()
                local ok, res = pcall(function() return rf:InvokeServer() end)
                notify("Social Reward", ok and ("ผลลัพธ์: " .. tostring(res)) or ("ล้มเหลว: " .. tostring(res)), 4)
            end)
        end,
    })
    secRewards:AddButton({
        Title = "แลกโค้ดฟรีทั้งหมดในเกม (Redeem All Codes)",
        Description = "ดึงรายชื่อโค้ดจาก RedeemCodesConfig (ได้ Coins/Gems/Tokens เพิ่มไว้เปิดสุ่มป้อมโหด)",
        ButtonText = "แลกทุกโค้ด",
        Callback = function()
            local rem = ReplicatedStorage:FindFirstChild("Remotes")
            local rf = rem and rem:FindFirstChild("RedeemCode")
            local rcMod = ReplicatedStorage:FindFirstChild("RedeemCodesConfig")
            if not (rf and rcMod and rcMod:IsA("ModuleScript")) then
                notify("Redeem Codes", "ไม่พบ RedeemCode หรือ RedeemCodesConfig", 4)
                return
            end
            task.spawn(function()
                local okM, cfg = pcall(require, rcMod)
                local codes = (okM and type(cfg) == "table" and cfg.CODES) or nil
                if type(codes) ~= "table" then
                    notify("Redeem Codes", "ไม่สามารถอ่านรายชื่อโค้ดได้", 4)
                    return
                end
                local claimed, already, failed = 0, 0, 0
                for code, _ in pairs(codes) do
                    if not Hub.alive then break end
                    local okR, res = pcall(function() return rf:InvokeServer(code) end)
                    if okR and type(res) == "table" and res.ok == true then
                        claimed += 1
                    elseif okR and type(res) == "table" and res.reason == "already" then
                        already += 1
                    else
                        failed += 1
                    end
                    task.wait(0.65)
                end
                notify("Redeem Codes", string.format("แลกสำเร็จ %d | เคยรับแล้ว %d | หมดอายุ/ไม่ผ่าน %d", claimed, already, failed), 5)
            end)
        end,
    })

    local secUtil = TabMisc:AddSection({ Title = "เครื่องมือ Lobby", Collapsible = false })
    secUtil:AddToggle({ Id = "AntiAFK", Title = "กันหลุด AFK (Anti-AFK)", Default = State.AntiAFK, Callback = function(v) setState("AntiAFK", v == true) end })
    secUtil:AddToggle({
        Id = "LearnCalls",
        Title = "บันทึก Remote (Read-Only Learn)",
        Default = false,
        Callback = function(v)
            State.Learn = v == true
            if State.Learn then installLearnHook() end
        end,
    })
    secUtil:AddButton({
        Title = "บันทึกผล Learn ลง TDHub_Learn.txt",
        ButtonText = "บันทึก",
        Callback = function()
            local ok, err, n = saveLearned()
            notify("Learn Mode", ok and ("บันทึก " .. n .. " บรรทัด") or ("ล้มเหลว: " .. tostring(err)), 4)
        end,
    })

    pcall(function() TabLobby:Select() end)
else
    -- ================= MATCH-ONLY UI =================
    local TabInfo = addTabSafe("สถานะด่าน", "info")
    local TabWin = addTabSafe("ฐาน & ชนะทุกด่าน", "crown")
    local TabAuto = addTabSafe("ออโต้แบบละเอียด", "zap")
    local TabMisc = addTabSafe("มุมมอง & เครื่องมือ", "eye")
    TabSettings = addTabSafe("ตั้งค่า", "settings")

    local secOverview = TabInfo:AddSection({ Title = "ข้อมูลผู้เล่น & ชุดป้อม", Collapsible = false })
    paraOverview = secOverview:AddParagraph({ Title = "ภาพรวม", Content = "กำลังโหลด..." })
    local secTelemetry = TabInfo:AddSection({ Title = "สถานะฐาน & ประตูทุกบาน (เรียลไทม์)", Collapsible = false })
    paraTelemetry = secTelemetry:AddParagraph({ Title = "รายละเอียด", Content = "กำลังโหลด..." })

    local secWin = TabWin:AddSection({ Title = "โหมดชนะอัตโนมัติ (เปิดค้างตลอด & จำค่าอัตโนมัติ)", Collapsible = false })
    paraStrategyPlan = secWin:AddParagraph({ Title = "แผน AI ปัจจุบัน (วาง/อัป/ขาย/ประตู)", Content = "กำลังโหลด..." })
    task.spawn(function() if getStrategyPlanText then setParaSafe(paraStrategyPlan, getStrategyPlanText()) end end)
    secWin:AddToggle({
        Id = "AutoWin",
        Title = "เปิด Auto Win (เล่นชนะทุกด่านอัตโนมัติ)",
        Description = "วางป้อมฟรี/ถูกสุดก่อน -> ปั๊มเงินด้วยฟาร์ม -> วาง DPS ใกล้ประตูที่กันน้อย -> อัปเกรด ROI + ซ่อม (<92%) และอัปประตูหลายบาน",
        Default = State.AutoWin,
        Callback = function(v) setState("AutoWin", v == true) end,
    })
    secWin:AddDropdown({
        Id = "WinStyle",
        Title = "สไตล์กลยุทธ์",
        Values = {
            "Balanced (ปั๊มเงิน+แรง+ถูก)",
            "Eco & MoneyRush (ตั้งฐานปั๊มเงินไว)",
            "Cheap DPS Rush (วางป้อมถูกแรงไว)",
        },
        Default = State.WinStyle,
        Callback = function(v) setState("WinStyle", v) end,
    })
    secWin:AddToggle({
        Id = "AutoDoorTargetUp",
        Title = "อัปเกรดประตูตามแผน (Auto Door Upgrade)",
        Description = "อัปประตูตามเลเวลเป้าหมายของคลื่นและช่วยอัปประตูเมื่อโดนตีหนักโดยไม่ทำให้เงินต้นเกมชะงัก",
        Default = State.AutoDoorTargetUp,
        Callback = function(v) setState("AutoDoorTargetUp", v == true) end,
    })
    secWin:AddDropdown({
        Id = "AutoAcceptTeamUp",
        Title = "โหมดเล่นทีม/บ้านร่วม (รับคำขอเข้าปุ่มเดียวกัน)",
        Values = { "ปิด", "เฉพาะเพื่อน (Friends)", "ทุกคน" },
        Default = State.AutoAcceptTeamUp,
        Callback = function(v) setState("AutoAcceptTeamUp", v) end,
    })
    secWin:AddToggle({
        Id = "AutoMoveToCell",
        Title = "เดินเข้าใกล้บล็อกอัตโนมัติ (แก้ You are too far)",
        Description = "ขยับเข้าใกล้เป้าหมายและรอตำแหน่งอัปเดตก่อนยิง Remote (ระยะจำกัด 30 studs ของเซิร์ฟเวอร์)",
        Default = State.AutoMoveToCell,
        Callback = function(v) setState("AutoMoveToCell", v == true) end,
    })
    secWin:AddToggle({
        Id = "AutoReplaceWeak",
        Title = "ขายป้อมถูก/ฟาร์มส่วนเกินเมื่อช่องเต็ม เพื่อวางตัวแรงกว่า",
        Description = "ขายป้อมดาเมจต่ำ (หรือฟาร์มส่วนเกินช่วงท้ายเกม) เพื่อเพิ่ม DPS สูงสุด",
        Default = State.AutoReplaceWeak,
        Callback = function(v) setState("AutoReplaceWeak", v == true) end,
    })
    secWin:AddButton({
        Title = "กดซ่อมประตูด่วนทันที (GatePatch)",
        Description = "ซ่อมทันทีถ้า Cooldown 8 วินาทีฝั่งเซิร์ฟเวอร์พร้อมแล้ว (AutoWin จะกดซ่อมให้ทันทีเมื่อประตู < 92%)",
        ButtonText = "ซ่อมประตู",
        Callback = function()
            local rf = tdRemote("GatePatch")
            local ready = attr("DoorRepairReadyAt")
            local srv = workspace:GetServerTimeNow()
            if not rf then
                notify("ซ่อมประตู", "ไม่พบ GatePatch", 3)
                return
            end
            if type(ready) == "number" and srv < ready then
                notify("ซ่อมประตู", string.format("เซิร์ฟเวอร์ติด Cooldown อีก %.1f วิ (AutoWin จะซ่อมทันทีที่พร้อม)", ready - srv), 3)
                return
            end
            rf:FireServer()
            notify("ซ่อมประตู", "ส่งคำสั่งซ่อมประตูแล้ว!", 2)
        end,
    })

    local function refreshBaseDropdown(forceFirst)
        local prevReal = baseLabelToName[State.SelectedBase]
        local list = scanBases()
        local chosen = nil
        if not forceFirst and prevReal then
            for lbl, rName in pairs(baseLabelToName) do
                if rName == prevReal then chosen = lbl break end
            end
        end
        chosen = chosen or list[1]
        State.SelectedBase = chosen
        -- Run UI rebuild in a fresh thread so calling TowerConfig/ClanDoors cannot taint Instance capability
        task.spawn(function()
            if ddBase and type(ddBase.SetValues) == "function" then
                pcall(function() ddBase:SetValues(list) end)
            end
            if ddBase and type(ddBase.SetValue) == "function" then
                pcall(function() ddBase:SetValue(chosen, true) end)
            end
        end)
        return list
    end

    -- Defer scanBases() out of UI construction so Match ModuleScripts never touch section creation thread
    local initialBases = { "(กำลังสแกนฐาน...)" }
    State.SelectedBase = initialBases[1]

    local secPvP = TabWin:AddSection({ Title = "โหมด PvP AI (Auto Ban + Pick + ส่งมอน + สกิล)", Collapsible = false })
    paraPvPStatus = secPvP:AddParagraph({ Title = "สถานะ PvP เรียลไทม์", Content = "กำลังโหลด..." })
    task.spawn(function() if getPvPStatusText then setParaSafe(paraPvPStatus, getPvPStatusText()) end end)
    secPvP:AddToggle({
        Id = "AutoPvPDraft",
        Title = "Auto Ban & Pick ตอนเริ่ม PvP (แบนตัวโกง + เลือก 6 ช่อง)",
        Description = "แบนตัวเมต้าอัตโนมัติในเฟส Ban แล้วจัดชุด MoneyMachine + DPS + MilitaryBase + Pet ในเฟส Pick",
        Default = State.AutoPvPDraft,
        Callback = function(v) setState("AutoPvPDraft", v == true) end,
    })
    secPvP:AddDropdown({
        Id = "PvPBanStyle",
        Title = "กลยุทธ์การแบน (Ban Priority)",
        Values = { "แบนตัวเมต้า (เว้นตัวเก่งของเรา)", "แบนตัวเมต้าสูงสุด (ทุกตัว)" },
        Default = State.PvPBanStyle,
        Callback = function(v) setState("PvPBanStyle", v) end,
    })
    secPvP:AddDropdown({
        Id = "PvPCustomBans",
        Title = "รายการตัวที่จะแบนก่อน (Custom Ban Targets)",
        Values = PVP_BAN_CHOICES,
        Multi = true,
        Default = (parseCsvList(State.PvPCustomBans)),
        Callback = function(v)
            local arr = parseCsvList(v)
            setState("PvPCustomBans", table.concat(arr, ","))
        end,
    })
    secPvP:AddDropdown({
        Id = "PvPSendMode",
        Title = "กลยุทธ์ส่งซอมบี้ PvP (Auto Send)",
        Values = { "สมดุล Eco + Rush ชนะไว", "ปั๊ม Eco เน้นรายได้", "สาย Rush ถล่มประตูไว", "ปิด (ไม่ส่งมอน)" },
        Default = State.PvPSendMode,
        Callback = function(v) setState("PvPSendMode", v) end,
    })
    secPvP:AddToggle({
        Id = "AutoPvPAbility",
        Title = "ใช้สกิล PvP อัตโนมัติ (Barricade / FrostNova / Purge / Overclock)",
        Default = State.AutoPvPAbility,
        Callback = function(v) setState("AutoPvPAbility", v == true) end,
    })
    secPvP:AddButton({
        Title = "ส่งคำสั่ง Ban / Pick ทันที (กรณีกดเองหรือโหลดเข้าหน้า Draft)",
        ButtonText = "Ban / Pick ทันที",
        Callback = function()
            if pvpTriggerDraftNow then task.spawn(pvpTriggerDraftNow) end
        end,
    })

    local secBase = TabWin:AddSection({ Title = "เลือกฐานเอง & ยึดฐานอัตโนมัติ", Collapsible = false })
    ddBase = secBase:AddDropdown({
        Id = "SelectedBase",
        Title = "เลือกฐานในด่าน (ประตู & พื้นที่วาง & สถานะ)",
        Values = initialBases,
        Default = initialBases[1],
        Callback = function(v) State.SelectedBase = v end,
    })
    secBase:AddButton({
        Title = "วาร์ปไปบ้านที่วางง่ายและกว้างที่สุดเดี๋ยวนี้ (แนะนำ)",
        ButtonText = "เลือกบ้านที่ดีที่สุด",
        Callback = function()
            local _, items = scanBases()
            local chosen = pickBestBaseItem(items, "1 ประตู + พื้นที่กว้างสุด (ชนะง่าย)")
            if not chosen then
                notify("เลือกบ้าน", "ไม่พบบ้านว่างในแผนที่ตอนนี้", 4)
                return
            end
            local ok, msg = teleportToBaseName(chosen.name)
            notify("เลือกบ้านที่ดีที่สุด", chosen.name .. " (" .. chosen.doors .. " ประตู, พื้นที่ " .. chosen.area .. "): " .. msg, ok and 4 or 4)
        end,
    })
    secBase:AddButton({
        Title = "รีเฟรชรายชื่อฐาน",
        ButtonText = "รีเฟรช",
        Callback = function()
            local list = refreshBaseDropdown(false)
            notify("รายชื่อฐาน", "พบ " .. #list .. " รายการ", 3)
        end,
    })
    secBase:AddButton({
        Title = "วาร์ปไปยึดฐานที่เลือก (UI ไม่หาย)",
        ButtonText = "วาร์ปยึดฐาน",
        Callback = function()
            local realName = baseLabelToName[State.SelectedBase] or State.SelectedBase
            local ok, msg = teleportToBaseName(realName)
            notify("เลือกฐาน", msg, ok and 3 or 4)
        end,
    })
    secBase:AddButton({
        Title = "ขอร่วมทีมกับฐานที่เลือก (TeamUpRequest)",
        ButtonText = "ขอร่วมทีม",
        Callback = function()
            local realName = baseLabelToName[State.SelectedBase] or State.SelectedBase
            local rf = tdRemote("TeamUpRequest")
            if not (rf and realName and realName ~= "" and housesFolder() and housesFolder():FindFirstChild(realName)) then
                notify("ร่วมทีม", "ต้องเลือกฐานที่มีอยู่จริงในด่านก่อน", 4)
                return
            end
            rf:FireServer(realName)
            notify("ร่วมทีม", "ส่งคำขอร่วมทีมไปที่ " .. realName .. " แล้ว", 3)
        end,
    })
    secBase:AddToggle({ Id = "AutoClaimBase", Title = "ยึดฐานอัตโนมัติเมื่อเข้าด่าน", Default = State.AutoClaimBase, Callback = function(v) setState("AutoClaimBase", v == true) end })
    secBase:AddDropdown({
        Id = "BasePreference",
        Title = "ความต้องการฐานอัตโนมัติ",
        Values = { "1 ประตู + พื้นที่กว้างสุด (ชนะง่าย)", "ฐานว่างใกล้สุด", "ฐาน 1 ประตู (ว่าง)", "ฐานหลายประตู (ว่าง)", "ตามที่เลือกใน Dropdown" },
        Default = State.BasePreference,
        Callback = function(v) setState("BasePreference", v) end,
    })

    local initialTypes = loadoutTypes()
    State.PlaceType = initialTypes[1]

    local secPlace = TabAuto:AddSection({ Title = "วางป้อมแบบกำหนดเอง (ปิดเมื่อใช้ Auto Win)", Collapsible = false })
    secPlace:AddToggle({ Id = "AutoPlace", Title = "วางป้อมอัตโนมัติ (ช่องว่างใกล้ตัวที่สุด)", Default = State.AutoPlace, Callback = function(v) setState("AutoPlace", v == true) end })
    local ddPlaceType = secPlace:AddDropdown({
        Id = "PlaceType",
        Title = "เลือกประเภทป้อม",
        Values = initialTypes,
        Default = initialTypes[1],
        Callback = function(v) State.PlaceType = v end,
    })
    secPlace:AddButton({
        Title = "วางป้อมตรงจุดที่ยืน (1 ครั้ง)",
        ButtonText = "วาง",
        Callback = function()
            local ok, msg = placeAtCharacter(State.PlaceType)
            notify("วางป้อม", msg, ok and 3 or 4)
        end,
    })
    secPlace:AddButton({
        Title = "รีเฟรชรายชื่อป้อมจาก Loadout",
        ButtonText = "รีเฟรช",
        Callback = function()
            local list = loadoutTypes()
            if ddPlaceType and type(ddPlaceType.SetValues) == "function" then ddPlaceType:SetValues(list) end
            State.PlaceType = list[1]
            notify("Loadout", table.concat(list, ", "), 4)
        end,
    })

    local secUpgrade = TabAuto:AddSection({ Title = "อัปเกรด & การเงิน", Collapsible = false })
    secUpgrade:AddToggle({ Id = "AutoUpgrade", Title = "อัปเกรดป้อมอัตโนมัติ", Default = State.AutoUpgrade, Callback = function(v) setState("AutoUpgrade", v == true) end })
    secUpgrade:AddDropdown({
        Id = "UpgradeOrder",
        Title = "ลำดับการอัปเกรด",
        Values = { "Cheapest first", "Income towers first", "Lowest level first", "Most expensive first" },
        Default = State.UpgradeOrder,
        Callback = function(v) setState("UpgradeOrder", v) end,
    })
    secUpgrade:AddSlider({ Id = "UpgradeInterval", Title = "หน่วงเวลาอัปเกรด (วินาที)", Min = 0.2, Max = 3.0, Default = State.UpgradeInterval, Rounding = 1, Callback = function(v) setState("UpgradeInterval", tonumber(v) or 0.6) end })
    secUpgrade:AddSlider({ Id = "CashReserve", Title = "เงินสำรองขั้นต่ำ (Cash Reserve)", Min = 0, Max = 25000, Default = State.CashReserve, Rounding = 0, Callback = function(v) setState("CashReserve", tonumber(v) or 0) end })
    secUpgrade:AddToggle({ Id = "AutoBank", Title = "ถอนเงินจาก Bank / Vault อัตโนมัติ", Default = State.AutoBank, Callback = function(v) setState("AutoBank", v == true) end })
    secUpgrade:AddSlider({ Id = "BankPct", Title = "ถอนเมื่อ Bank เต็มอย่างน้อย (%)", Min = 10, Max = 100, Default = State.BankPct, Rounding = 0, Callback = function(v) setState("BankPct", tonumber(v) or 90) end })
    secUpgrade:AddToggle({ Id = "AutoGolemForge", Title = "กด Golem Forge อัตโนมัติเมื่อ Ready", Default = State.AutoGolemForge, Callback = function(v) setState("AutoGolemForge", v == true) end })

    local secDoorEnd = TabAuto:AddSection({ Title = "ประตูหลายบาน & จบด่าน", Collapsible = false })
    secDoorEnd:AddToggle({ Id = "AutoRepair", Title = "ซ่อมประตูอัตโนมัติ (รองรับหลายประตู)", Default = State.AutoRepair, Callback = function(v) setState("AutoRepair", v == true) end })
    secDoorEnd:AddSlider({ Id = "RepairBelow", Title = "ซ่อมเมื่อ HP ประตูต่ำกว่า (%)", Min = 10, Max = 99, Default = State.RepairBelow, Rounding = 0, Callback = function(v) setState("RepairBelow", tonumber(v) or 50) end })
    secDoorEnd:AddToggle({ Id = "AutoDoorUp", Title = "อัปเกรดประตูอัตโนมัติ (รองรับหลายประตู)", Default = State.AutoDoorUp, Callback = function(v) setState("AutoDoorUp", v == true) end })
    secDoorEnd:AddToggle({ Id = "AutoFree2X", Title = "ใช้ Free 2X ท้ายเกมอัตโนมัติ (ถ้ามี Token)", Default = State.AutoFree2X, Callback = function(v) setState("AutoFree2X", v == true) end })
    secDoorEnd:AddToggle({ Id = "AutoPlayAgain", Title = "โหวต Play Again อัตโนมัติเมื่อจบด่าน", Default = State.AutoPlayAgain, Callback = function(v) setState("AutoPlayAgain", v == true) end })

    local secSpeed = TabAuto:AddSection({ Title = "ความเร็วเกม (2x / 3x / 4x)", Collapsible = false })
    paraSpeedStatus = secSpeed:AddParagraph({ Title = "สถานะความเร็ว", Content = "กำลังโหลดข้อมูล..." })
    task.spawn(function() setParaSafe(paraSpeedStatus, buildSpeedStatusText()) end)
    secSpeed:AddToggle({
        Id = "AutoSpeed",
        Title = "ล็อกความเร็วเกมอัตโนมัติ (เปิดเมื่อเวฟเริ่ม)",
        Description = "รักษาระดับความเร็วที่เลือกให้อัตโนมัติระหว่างสู้ (Default ปิดไว้ ให้เปิดเองได้)",
        Default = State.AutoSpeed,
        Callback = function(v) setState("AutoSpeed", v == true) end,
    })
    secSpeed:AddDropdown({
        Id = "SpeedTarget",
        Title = "ความเร็วเป้าหมาย",
        Values = { "สูงสุดที่มี (4x->3x->2x)", "2x", "3x (ต้องมี VIP)", "4x (ต้องมีเวลา 4x)", "1x (ปกติ)" },
        Default = State.SpeedTarget,
        Callback = function(v) setState("SpeedTarget", v) end,
    })
    secSpeed:AddButton({
        Title = "สลับความเร็ว 2x (ฟรี)",
        ButtonText = "2x เปิด/ปิด",
        Callback = function()
            local ok, msg = applySpeedMultiplier(2, true)
            notify("Game Speed 2x", msg or (ok and "สำเร็จ" or "ไม่สำเร็จ"), 3)
        end,
    })
    secSpeed:AddButton({
        Title = "สลับความเร็ว 3x (ต้องมี VIP)",
        ButtonText = "3x ความเร็ว",
        Callback = function()
            local ok, msg = applySpeedMultiplier(3, true)
            notify("Game Speed 3x", msg or (ok and "สำเร็จ" or "ไม่สำเร็จ"), 3)
        end,
    })
    secSpeed:AddButton({
        Title = "สลับความเร็ว 4x (ต้องมีเวลา 4x)",
        ButtonText = "4x ความเร็ว",
        Callback = function()
            local ok, msg = applySpeedMultiplier(4, true)
            notify("Game Speed 4x", msg or (ok and "สำเร็จ" or "ไม่สำเร็จ"), 3)
        end,
    })
    secSpeed:AddButton({
        Title = "รีเซ็ตความเร็วกลับ 1x ปกติ",
        ButtonText = "กลับ 1x",
        Callback = function()
            local ok, msg = applySpeedMultiplier(1, false)
            notify("Game Speed 1x", msg or (ok and "สำเร็จ" or "ไม่สำเร็จ"), 3)
        end,
    })

    local secEsp = TabMisc:AddSection({ Title = "มุมมอง (Monster ESP)", Collapsible = false })
    secEsp:AddToggle({ Id = "MonsterESP", Title = "เปิด Monster ESP (ไฮไลต์มอนสเตอร์)", Default = State.MonsterESP, Callback = function(v) setState("MonsterESP", v == true) end })
    secEsp:AddSlider({ Id = "ESPMax", Title = "จำนวน Highlight สูงสุด", Min = 5, Max = 60, Default = State.ESPMax, Rounding = 0, Callback = function(v) setState("ESPMax", tonumber(v) or 25) end })

    local secUtil = TabMisc:AddSection({ Title = "เครื่องมือ Match & Learn", Collapsible = false })
    secUtil:AddToggle({ Id = "AntiAFK", Title = "กันหลุด AFK (Anti-AFK)", Default = State.AntiAFK, Callback = function(v) setState("AntiAFK", v == true) end })
    secUtil:AddToggle({
        Id = "LearnCalls",
        Title = "บันทึก Remote (Read-Only Learn)",
        Default = false,
        Callback = function(v)
            State.Learn = v == true
            if State.Learn then installLearnHook() end
        end,
    })
    secUtil:AddButton({
        Title = "บันทึกผล Learn ลง TDHub_Learn.txt",
        ButtonText = "บันทึก",
        Callback = function()
            local ok, err, n = saveLearned()
            notify("Learn Mode", ok and ("บันทึก " .. n .. " บรรทัด") or ("ล้มเหลว: " .. tostring(err)), 4)
        end,
    })

    pcall(function() TabWin:Select() end)
end

-- ---------------------------------------------------------------- Shared Settings Tab
TabSettings:AddToggle({
    Id = "AutoReload",
    Title = "เปิดสคริปต์ซ้ำอัตโนมัติเมื่อเข้าด่าน / ย้าย Place",
    Description = "แก้ปัญหา UI หายตอนวาร์ปจาก Lobby เข้าด่าน (queue_on_teleport)",
    Default = State.AutoReload,
    Callback = function(v) setState("AutoReload", v == true) end,
})
TabSettings:AddButton({
    Title = "ปิดสคริปต์ (Unload)",
    Description = "ปิดหน้าต่าง หยุดทุกลูป และลบ ESP ทั้งหมด",
    ButtonText = "Unload",
    Callback = function() Hub.Destroy() end,
})

if SaveManager and InterfaceManager then
    local okSettings, errSettings = pcall(function()
        SaveManager:SetLibrary(Fluent)
        InterfaceManager:SetLibrary(Fluent)
        SaveManager:IgnoreThemeSettings()
        InterfaceManager:SetFolder(CONFIG.InterfaceFolder)
        SaveManager:SetFolder(CONFIG.ConfigFolder)
        if type(InterfaceManager.Settings) == "table" then
            InterfaceManager.Settings.MenuKeybind = CONFIG.ToggleKey.Name
        end
        InterfaceManager:BuildInterfaceSection(TabSettings)
        if not isMobile and Fluent.MinimizeKeybind then
            local kb = Fluent.MinimizeKeybind
            local function syncKey(val)
                if typeof(val) == "EnumItem" and val.EnumType == Enum.KeyCode then
                    activeToggleKey = val
                    if type(InterfaceManager.Settings) == "table" then
                        InterfaceManager.Settings.MenuKeybind = val.Name
                    end
                    pcall(function() InterfaceManager:SaveSettings() end)
                elseif type(val) == "string" and Enum.KeyCode[val] then
                    activeToggleKey = Enum.KeyCode[val]
                end
            end
            local v = kb.Value
            if typeof(v) ~= "EnumItem" or v == Enum.KeyCode.Unknown then
                kb:SetValue(CONFIG.ToggleKey, true)
                activeToggleKey = CONFIG.ToggleKey
                if type(InterfaceManager.Settings) == "table" then
                    InterfaceManager.Settings.MenuKeybind = CONFIG.ToggleKey.Name
                end
                pcall(function() InterfaceManager:SaveSettings() end)
            else
                syncKey(v)
            end
            kb:OnChanged(function() task.defer(function() syncKey(kb.Value) end) end)
        end
        SaveManager:BuildConfigSection(TabSettings)
    end)
    if not okSettings then warn("[TDHub] settings section failed: " .. tostring(errSettings)) end
end

-- ---------------------------------------------------------------- Anti-AFK & Live HUD loop
track(LocalPlayer.Idled:Connect(function()
    if Hub.alive and State.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

local function buildOverviewText()
    return string.format(
        "โหมดปัจจุบัน: %s (PlaceId %s)\nCoins: %s | Gems: %s | Level: %s (XP %s)\nWins %s / Losses %s | Free 2X: %s | BP Points: %s\nLoadout: %s",
        IS_MATCH and "Match (ในด่าน)" or "Lobby (หน้าหลัก)",
        tostring(game.PlaceId),
        tostring(attr("Coins") or 0),
        tostring(attr("Gems") or 0),
        tostring(attr("XPLevel") or 0),
        tostring(attr("XP") or 0),
        tostring(attr("TotalWins") or 0),
        tostring(attr("TotalLosses") or 0),
        tostring(attr("Free2X") or 0),
        tostring(attr("BattlePassPoints") or 0),
        tostring(attr("TowerLoadout") or "-")
    )
end

local function buildTelemetryText()
    if IS_MATCH then
        local mons = workspace:FindFirstChild("MonsterSystem")
        local towers = workspace:FindFirstChild("PlacedTowers")
        local cash = cashValue()
        local h = myHouse()
        local myCount, totalCount = 0, towers and #towers:GetChildren() or 0
        if towers then
            for _, t in ipairs(towers:GetChildren()) do
                if t:GetAttribute("OwnerUserId") == LocalPlayer.UserId then myCount += 1 end
            end
        end
        local doorStr = "ยังไม่เลือกฐาน (เลือกได้ในแท็บ 'ฐาน & ชนะทุกด่าน')"
        if h then
            local doors = getDoorsInfo(h)
            if #doors > 1 then
                local parts = {}
                for _, d in ipairs(doors) do
                    parts[#parts + 1] = d.broken and string.format("D%d:[พัง]", d.index) or string.format("D%d:Lv.%d(%.0f%%)", d.index, d.level, d.pct)
                end
                doorStr = string.format("%s (%d ประตู) | %s", h.Name, #doors, table.concat(parts, " "))
            elseif #doors == 1 then
                local d = doors[1]
                local broken = d.broken and " [พัง]" or ""
                doorStr = string.format("%s | Door Lv.%d HP %.0f/%.0f (%.0f%%)%s", h.Name, d.level, d.hp, d.maxHp, d.pct, broken)
            end
        end
        return string.format(
            "Cash: %s | Match Time: %ss | Speed: %dx | AutoWin: %s\n%s\nป้อมของคุณ: %d (ทั้งหมด %d) | มอนสเตอร์: %s",
            cash and tostring(cash.Value) or "0",
            tostring(math.floor(num(attr("MatchSeconds")))),
            getCurrentSpeedMultiplier(),
            State.AutoWin and "ON" or "OFF",
            doorStr,
            myCount,
            totalCount,
            mons and tostring(#mons:GetChildren()) or "0"
        )
    end

    -- Lobby owned towers & recommended best loadout summary
    local owned = getOwnedTowers()
    local ownedList = {}
    for name, info in pairs(owned) do
        ownedList[#ownedList + 1] = string.format("%s(Lv.%d)", name, info.maxOwned)
    end
    table.sort(ownedList)
    local rec = computeBestOwnedLoadout(State.LoadoutPreset)
    return string.format(
        "Best Wave — Easy: %s | Hard: %s | Nightmare: %s\nป้อมที่มี: %s\nชุดแนะนำ (%s): %s",
        tostring(attr("BestWaveEasy") or 0),
        tostring(attr("BestWaveHard") or 0),
        tostring(attr("BestWaveNightmare") or 0),
        #ownedList > 0 and table.concat(ownedList, ", ") or "-",
        State.LoadoutPreset,
        table.concat(rec, ", ")
    )
end

local lastHouseCount = -1
task.spawn(function()
    while Hub.alive do
        if IS_MATCH and ddBase then
            local hs = housesFolder()
            local n = hs and #hs:GetChildren() or 0
            if n > 0 and (n ~= lastHouseCount or not baseLabelToName[State.SelectedBase]) then
                lastHouseCount = n
                local prevReal = baseLabelToName[State.SelectedBase]
                local okScan, list = pcall(scanBases)
                if okScan and type(list) == "table" and #list > 0 then
                    local chosen = nil
                    if prevReal then
                        for lbl, rName in pairs(baseLabelToName) do
                            if rName == prevReal then chosen = lbl break end
                        end
                    end
                    chosen = chosen or list[1]
                    State.SelectedBase = chosen
                    task.spawn(function()
                        if type(ddBase.SetValues) == "function" then pcall(function() ddBase:SetValues(list) end) end
                        if type(ddBase.SetValue) == "function" then pcall(function() ddBase:SetValue(chosen, true) end) end
                    end)
                end
            end
        end
        task.spawn(function()
            if paraOverview then setParaSafe(paraOverview, buildOverviewText()) end
            if paraTelemetry then setParaSafe(paraTelemetry, buildTelemetryText()) end
            if paraSpeedStatus then setParaSafe(paraSpeedStatus, buildSpeedStatusText()) end
            if paraPvPStatus and getPvPStatusText then setParaSafe(paraPvPStatus, getPvPStatusText()) end
            if paraStrategyPlan and getStrategyPlanText then setParaSafe(paraStrategyPlan, getStrategyPlanText()) end
            if paraChestInfo and getChestInfoText then setParaSafe(paraChestInfo, getChestInfoText()) end
            if paraPetInfo and getPetInfoText then setParaSafe(paraPetInfo, getPetInfoText()) end
        end)
        task.wait(0.6)
    end
end)

-- Use hub_state.json as single source of truth across Lobby/Match teleports (do not let legacy SaveManager autoload overwrite State)
saveHubState()

notify("TD Hub v2.3 โหลดแล้ว", IS_MATCH and "เข้าด่านแล้ว: Auto Win + ขายป้อมเก่า + เข้าใกล้บล็อก เปิดใช้งานอัตโนมัติ!" or "หน้า Lobby: แสดงเฉพาะฟังก์ชัน Lobby (กดแลกโค้ด & จัด Loadout ได้เลย)", 4)
