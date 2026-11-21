--[[
    ========================================================================
    TD Hub - Production Key System Loader
    รองรับ: Linkvertise, LootLabs, Work.ink (ผ่าน Platoboost, PandaAuth หรือ Custom API)
    ฟังก์ชัน:
      - ตรวจสอบ Key อัตโนมัติจากไฟล์เซฟ (ไม่ต้องกรอกซ้ำถ้าคีย์ยังไม่หมดอายุ)
      - มี Master Key สำหรับเจ้าของสคริปต์ (ข้ามโฆษณาเข้าใช้งานได้ทันที)
      - ระบบ UI สวยงาม (FluentStudio Dark Acrylic)
      - ปุ่มคัดลอกลิงก์ Get Key ลง Clipboard
      - โหลดสคริปต์หลักผ่าน loadstring / raw URL หรือ Local File
    ========================================================================
]]

if not game:IsLoaded() then
    pcall(function() game.Loaded:Wait() end)
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")

while not Players.LocalPlayer do
    task.wait(0.1)
end
local LocalPlayer = Players.LocalPlayer

-- ========================================================================
-- 1. การตั้งค่าระบบ KEY (แก้ไขข้อมูลของคุณที่นี่)
-- ========================================================================
local SETTINGS = {
    -- ลิงก์ที่ให้ผู้เล่นกดไปเอา Key (Work.ink / LootLabs / Linkvertise / Platoboost)
    GetKeyUrl = "https://work.ink/3bwE/td-hub-get-key",

    -- ผู้ให้บริการที่ใช้ตรวจสอบคีย์: "Work.ink" หรือ "Platoboost" หรือ "PandaAuth" หรือ "Custom"
    Provider = "Work.ink",

    -- ตั้งค่าเฉพาะ Work.ink Key System
    WorkInk = {
        LinkId = "5076357", -- Link ID จาก Work.ink ของคุณ
        MaxAgeSeconds = 6 * 3600, -- 6 ชั่วโมง (21,600 วินาที)
    },

    -- ตั้งค่าเฉพาะ Platoboost (ถ้าใช้)
    Platoboost = {
        PublicKey = "YOUR_PUBLIC_KEY_HERE", -- นำ Public Key จาก Platoboost Dashboard มาใส่
    },

    -- ตั้งค่าเฉพาะ PandaAuth (ถ้าใช้)
    PandaAuth = {
        ServiceId = "YOUR_SERVICE_ID_HERE",
    },

    -- ตั้งค่าเฉพาะ Custom Web API (ถ้าเขียน Server เช็คเอง)
    Custom = {
        VerifyUrl = "https://your-api.com/verify",
    },

    -- Master Keys พิเศษสำหรับตัวคุณเอง/ทีมงาน (ใส่คีย์นี้จะผ่านทันที ไม่ต้องกดโฆษณา)
    DeveloperKeys = {
        "OWNER_DEV_BYPASS_2026",
        "TD_HUB_ADMIN_TEST",
    },

    -- สคริปต์หลักที่ต้องการให้โหลดเมื่อคีย์ผ่านแล้ว
    MainScript = {
        Mode = "Auto", -- "Auto" (ลอง Web ก่อนถ้าไม่ได้ใช้ Local), "Web", "Local"
        WebUrl = "https://raw.githubusercontent.com/mjkotan/TDHub/main/TD_Hub.lua",
        LocalPath = "TDHub/TD_Hub.lua",
    },

    -- ที่อยู่ไฟล์เก็บคีย์ในเครื่อง
    KeyFile = "TDHub/saved_key.txt",
    DiscordContact = "shiroeza_01",
    DiscordLink = "https://discord.gg/",
}

-- ========================================================================
-- 2. ระบบ HWID & Request Helper
-- ========================================================================
local function getHwid()
    local hwid = nil
    if type(gethwid) == "function" then
        pcall(function() hwid = gethwid() end)
    end
    if not hwid or #tostring(hwid) < 4 then
        pcall(function() hwid = RbxAnalyticsService:GetClientId() end)
    end
    if not hwid or #tostring(hwid) < 4 then
        hwid = "USER_" .. tostring(LocalPlayer.UserId)
    end
    return tostring(hwid)
end

local HWID = getHwid()

local function httpRequest(options)
    local fn = (syn and syn.request) or (http and http.request) or http_request or request
    if type(fn) == "function" then
        return fn(options)
    end
    if options.Method == "GET" and type(game.HttpGet) == "function" then
        local ok, body = pcall(game.HttpGet, game, options.Url)
        if ok then return { StatusCode = 200, Body = body } end
    end
    return nil
end

-- ========================================================================
-- 3. ตรวจสอบความถูกต้องของ Key
-- ========================================================================
local function verifyKey(rawKey)
    if not rawKey or type(rawKey) ~= "string" then return false, "กรุณากรอก Key" end
    local cleanKey = rawKey:gsub("%s+", "")
    if #cleanKey == 0 then return false, "กรุณากรอก Key" end

    -- 1. เช็ก Master / Developer Key
    for _, devKey in ipairs(SETTINGS.DeveloperKeys) do
        if cleanKey == devKey then
            return true, "ยินดีต้อนรับ Developer!"
        end
    end

    -- 2. ตรวจสอบผ่าน API Provider ที่เลือก
    if SETTINGS.Provider == "Work.ink" then
        local url = string.format("https://work.ink/_api/v2/token/isValid/%s", cleanKey)
        local res = httpRequest({ Url = url, Method = "GET" })
        if res and res.Body then
            local okDec, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if okDec and type(data) == "table" then
                if data.valid == true then
                    if SETTINGS.WorkInk and SETTINGS.WorkInk.LinkId and data.info and data.info.linkId then
                        if tostring(data.info.linkId) ~= tostring(SETTINGS.WorkInk.LinkId) then
                            return false, "Key นี้ไม่ได้มาจากลิงก์ของ TD Hub"
                        end
                    end
                    return true, "ยืนยันคีย์สำเร็จ!"
                end
            end
        end
        return false, "Key ไม่ถูกต้องหรือหมดอายุแล้ว"

    elseif SETTINGS.Provider == "Platoboost" then
        local url = string.format(
            "https://api.platoboost.com/public/whitelist/check?public_key=%s&key=%s&hwid=%s",
            SETTINGS.Platoboost.PublicKey,
            cleanKey,
            HWID
        )
        local res = httpRequest({ Url = url, Method = "GET" })
        if res and res.Body then
            local okDec, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if okDec and type(data) == "table" then
                if data.status == 200 and data.data and data.data.valid == true then
                    return true, "ยืนยันคีย์สำเร็จ!"
                elseif data.message then
                    return false, tostring(data.message)
                end
            end
        end
        return false, "Key ไม่ถูกต้องหรือหมดอายุแล้ว"

    elseif SETTINGS.Provider == "PandaAuth" then
        local url = string.format(
            "https://pandadevelopment.net/api/v1/whitelist/verify?service=%s&hwid=%s&key=%s",
            SETTINGS.PandaAuth.ServiceId,
            HWID,
            cleanKey
        )
        local res = httpRequest({ Url = url, Method = "GET" })
        if res and res.Body then
            local okDec, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if okDec and type(data) == "table" and (data.authenticated == true or data.valid == true) then
                return true, "ยืนยันคีย์สำเร็จ!"
            end
        end
        return false, "Key ไม่ถูกต้องหรือหมดอายุแล้ว"

    elseif SETTINGS.Provider == "Custom" then
        local url = string.format(
            "%s?key=%s&hwid=%s",
            SETTINGS.Custom.VerifyUrl,
            cleanKey,
            HWID
        )
        local res = httpRequest({ Url = url, Method = "GET" })
        if res and res.Body then
            local okDec, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if okDec and type(data) == "table" and (data.valid == true or data.success == true) then
                return true, "ยืนยันคีย์สำเร็จ!"
            end
        end
        return false, "Key ไม่ถูกต้องหรือหมดอายุแล้ว"
    end

    return false, "ยังไม่ได้กำหนดระบบ Provider"
end

-- ========================================================================
-- 4. โหลดสคริปต์หลัก (Launch Main Script)
-- ========================================================================
local function launchMainHub()
    print("[TDHub Loader] Key Verified! Launching Main Hub...")

    -- ป้องกันการรันซ้ำ
    if getgenv and getgenv().__TDHub and getgenv().__TDHub.alive then
        print("[TDHub Loader] TDHub already active.")
        return
    end

    local code = nil
    local mode = SETTINGS.MainScript.Mode

    if mode == "Auto" or mode == "Local" then
        if type(isfile) == "function" and type(readfile) == "function" then
            local okEx, exists = pcall(isfile, SETTINGS.MainScript.LocalPath)
            if okEx and exists then
                local okRead, text = pcall(readfile, SETTINGS.MainScript.LocalPath)
                if okRead and type(text) == "string" and #text > 500 then
                    code = text
                end
            end
        end
    end

    if not code and (mode == "Auto" or mode == "Web") then
        local okHttp, text = pcall(function()
            return game:HttpGet(SETTINGS.MainScript.WebUrl)
        end)
        if okHttp and type(text) == "string" and #text > 500 then
            code = text
        end
    end

    if code then
        local fn, err = loadstring(code)
        if fn then
            local okRun, rerr = pcall(fn)
            if not okRun then
                warn("[TDHub Loader] Runtime error in main script:", rerr)
            end
        else
            warn("[TDHub Loader] Compile error in main script:", err)
        end
    else
        warn("[TDHub Loader] Failed to load main script source.")
    end
end

-- ========================================================================
-- 5. ตรวจสอบคีย์ที่บันทึกไว้ก่อน (Silent Auto-Login + เช็คอายุ 6 ชั่วโมง)
-- ========================================================================
if type(isfile) == "function" and type(readfile) == "function" then
    local okEx, exists = pcall(isfile, SETTINGS.KeyFile)
    if okEx and exists then
        local okRead, savedRaw = pcall(readfile, SETTINGS.KeyFile)
        if okRead and type(savedRaw) == "string" and #savedRaw > 3 then
            local keyStr = savedRaw:gsub("%s+", "")
            local isExpired = false
            local okDec, json = pcall(function() return HttpService:JSONDecode(savedRaw) end)
            if okDec and type(json) == "table" and json.key then
                keyStr = tostring(json.key)
                local maxAge = SETTINGS.WorkInk.MaxAgeSeconds or (6 * 3600)
                if json.savedAt and (os.time() - json.savedAt) > maxAge then
                    isExpired = true
                end
            end

            if isExpired then
                print("[TDHub Loader] Saved Key expired after 6 hours. Requesting new key...")
                if type(delfile) == "function" then pcall(delfile, SETTINGS.KeyFile) end
            else
                local isValid = verifyKey(keyStr)
                if isValid then
                    print("[TDHub Loader] Saved Key is valid within 6 hours. Skipping UI!")
                    launchMainHub()
                    return
                else
                    if type(delfile) == "function" then pcall(delfile, SETTINGS.KeyFile) end
                end
            end
        end
    end
end

-- ========================================================================
-- 6. โหลด Fluent UI สำหรับหน้าต่างกรอก Key
-- ========================================================================
local function loadFluentLibrary()
    local localPath = "TDHub/ui/FluentStudio.luau"
    if type(isfile) == "function" and type(readfile) == "function" then
        local okE, exists = pcall(isfile, localPath)
        if okE and exists then
            local okR, text = pcall(readfile, localPath)
            if okR and type(text) == "string" and #text > 1000 then
                local fn = loadstring(text)
                if fn then return fn() end
            end
        end
    end
    -- Fallback โหลดจาก Web
    local okW, text = pcall(game.HttpGet, game, "https://raw.githubusercontent.com/mjkotan/FluentStudio/main/build/FluentStudio.luau")
    if okW and type(text) == "string" then
        local fn = loadstring(text)
        if fn then return fn() end
    end
    return nil
end

local Fluent = loadFluentLibrary()
if not Fluent then
    warn("[TDHub Loader] Could not load Fluent UI Library!")
    return
end

local KeyWindow = Fluent:CreateWindow({
    Title = "TD Hub",
    SubTitle = "Key System (อายุ 6 ชม.)",
    TabWidth = 150,
    Size = UDim2.fromOffset(500, 360),
    Acrylic = true,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.RightControl
})

local function notify(title, content, duration)
    pcall(function()
        if KeyWindow and type(KeyWindow.Notify) == "function" then
            KeyWindow:Notify({ Title = title, Content = content, Duration = duration or 4 })
        elseif Fluent and type(Fluent.Notify) == "function" then
            Fluent:Notify({ Title = title, Content = content, Duration = duration or 4 })
        end
    end)
end

local TabKey = KeyWindow:AddTab({ Title = "เข้าสู่ระบบ Key", Icon = "key" })
local TabContact = KeyWindow:AddTab({ Title = "ติดต่อรับ Key", Icon = "user" })

TabKey:AddParagraph({
    Title = "วิธีรับ Key (Work.ink)",
    Content = "1. กดปุ่ม 'คัดลอกลิงก์ Get Key' ด้านล่าง\n2. นำไปเปิดใน Browser แล้วผ่านโฆษณาเพื่อรับ Key ฟรี\n3. Key มีเวลาใช้งาน 6 ชั่วโมง (ไม่ต้องหาใหม่จนกว่าจะหมดเวลา)\n4. นำ Key มาวางในช่องด้านล่าง แล้วกด 'ตรวจสอบ Key & เข้าใช้งาน'\n5. หรือติดต่อรับ Key โดยตรงได้ที่ Discord: shiroeza_01"
})

local enteredKey = ""
local KeyInput = TabKey:AddInput({
    Id = "KeyInputField",
    Title = "กรอก Key ของคุณ",
    Default = "",
    Placeholder = "วาง Key ที่ได้จาก Work.ink หรือ Developer Key...",
    Numeric = false,
    Finished = false,
    Callback = function(val)
        enteredKey = val
    end
})

TabKey:AddButton({
    Title = "ตรวจสอบ Key & เข้าใช้งาน",
    Description = "ตรวจเช็กความถูกต้องและบันทึกคีย์ลงเครื่อง (อายุ 6 ชม.)",
    Callback = function()
        notify("กำลังตรวจสอบ", "กำลังตรวจสอบ Key กับระบบ Work.ink...", 2)
        task.wait(0.3)
        local ok, msg = verifyKey(enteredKey)
        if ok then
            -- บันทึกคีย์ลงเครื่องพร้อม Timestamp 6 ชั่วโมง
            if type(writefile) == "function" then
                pcall(function()
                    if type(makefolder) == "function" then makefolder("TDHub") end
                    local payload = {
                        key = enteredKey:gsub("%s+", ""),
                        savedAt = os.time(),
                        maxAge = SETTINGS.WorkInk.MaxAgeSeconds or (6 * 3600),
                    }
                    writefile(SETTINGS.KeyFile, HttpService:JSONEncode(payload))
                end)
            end
            notify("สำเร็จ!", msg or "Key ถูกต้อง! มีอายุ 6 ชั่วโมง กำลังเปิด TD Hub...", 3)
            task.wait(0.8)
            KeyWindow:Destroy()
            launchMainHub()
        else
            notify("ข้อผิดพลาด", msg or "Key ไม่ถูกต้องหรือหมดอายุแล้ว กรุณาลองใหม่", 4)
        end
    end
})

TabKey:AddButton({
    Title = "คัดลอกลิงก์ Get Key",
    Description = "คลิกเพื่อคัดลอกลิงก์ Work.ink ไปเปิดในเบราว์เซอร์เพื่อรับ Key ฟรี",
    Callback = function()
        local setclip = setclipboard or toclipboard or (Clipboard and Clipboard.set)
        if type(setclip) == "function" then
            setclip(SETTINGS.GetKeyUrl)
            notify("คัดลอกสำเร็จ", "คัดลอกลิงก์ Work.ink แล้ว นำไปวางในเบราว์เซอร์ได้เลย", 3)
        else
            notify("ไม่รองรับ Clipboard", "Executor ของคุณไม่รองรับ setclipboard", 3)
        end
    end
})

-- แท็บติดต่อรับ Key / ซัพพอร์ต
TabContact:AddParagraph({
    Title = "ติดต่อรับ Key / ซัพพอร์ตโดยตรง",
    Content = "หากไม่สะดวกดูโฆษณา หรือเจอปัญหา Key ไม่ผ่าน\nสามารถแอด Discord เพื่อติดต่อรับ Key หรือแจ้งปัญหาได้ที่:\n\nDiscord: shiroeza_01"
})

TabContact:AddButton({
    Title = "คัดลอก Discord: shiroeza_01",
    Description = "คลิกเพื่อคัดลอกชื่อ Discord นำไปกด Add Friend ได้เลย",
    Callback = function()
        local setclip = setclipboard or toclipboard or (Clipboard and Clipboard.set)
        if type(setclip) == "function" then
            setclip(SETTINGS.DiscordContact)
            notify("คัดลอก Discord สำเร็จ", "คัดลอก 'shiroeza_01' แล้ว นำไปแอดเพื่อนใน Discord ได้เลย", 3)
        end
    end
})

if #SETTINGS.DiscordLink > 10 then
    TabContact:AddButton({
        Title = "คัดลอกลิงก์ Discord Server",
        Description = "เข้าร่วมเซิร์ฟเวอร์ Discord เพื่อรับการแจ้งเตือนอัปเดต",
        Callback = function()
            local setclip = setclipboard or toclipboard or (Clipboard and Clipboard.set)
            if type(setclip) == "function" then
                setclip(SETTINGS.DiscordLink)
                notify("คัดลอกลิงก์ Discord แล้ว", "นำลิงก์ไปวางในเบราว์เซอร์เพื่อเข้าร่วม Discord", 2.5)
            end
        end
    })
end

notify("TD Hub", "กรุณากรอก Key (มีอายุ 6 ชม.) หรือกดรับ Key จาก Work.ink", 5)
