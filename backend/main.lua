local millennium = require("millennium")
local fs = require("fs")
local m_utils = require("utils")
local cjson = require("json")
local logger = require("logger")
local auth = require("auth")

local SOURCES = {
    {
        name = "Morrenus",
        url = "https://hubcapmanifest.com/api/v1/manifest/<appid>?api_key=<moapikey>",
    },
    {
        name = "Luie",
        url = "https://lua.tools/api/manifest/download?appid=<appid>&source=Luie",
        needsLogin = true,
    },
    {
        name = "Ryuu",
        url = "http://167.235.229.108/<appid>",
    },
    {
        name = "TwentyTwo Cloud",
        url = "https://api.twentytwocloud.com/download?appid=<appid>",
    },
    {
        name = "Sushi",
        url = "https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/<appid>.zip",
    },
}

local DEFAULT_SETTINGS = {
    fastFetch = true,
    morrenusApiKey = "",
    theme = "original",
    useSteamLanguage = true,
}

local states = {}

local function encode(value)
    local success, result = pcall(cjson.encode, value)
    if success then return result end
    return '{"success":false,"error":"Could not encode response"}'
end

local function error_response(message)
    return encode({
        success = false,
        error = tostring(message),
    })
end

local function base64_encode(data)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((data:gsub(".", function(byte)
        local bits = ""
        local value = byte:byte()
        for i = 8, 1, -1 do
            bits = bits .. (value % 2 ^ i - value % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return bits
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
        if #bits < 6 then return "" end
        local value = 0
        for i = 1, 6 do
            value = value + (bits:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
        end
        return alphabet:sub(value + 1, value + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local saved_settings = nil

local function steam_path()
    local success, path = pcall(millennium.steam_path)
    if success and type(path) == "string" and path ~= "" then return path end
    return nil
end

local function temp_root()
    local root = m_utils.getenv("TEMP") or m_utils.getenv("TMP") or m_utils.getenv("LOCALAPPDATA")
    if not root or root == "" then return nil end

    local directory = fs.join(root, "LuaTools")
    if not fs.exists(directory) then fs.create_directories(directory) end
    return directory
end

local function settings_path()
    local path = steam_path()
    if not path then return nil end
    return fs.join(path, "millennium", "plugins", "luatools-settings.json")
end

local function settings()
    if saved_settings then return saved_settings end

    local values = {
        fastFetch = DEFAULT_SETTINGS.fastFetch,
        morrenusApiKey = DEFAULT_SETTINGS.morrenusApiKey,
        theme = DEFAULT_SETTINGS.theme,
        useSteamLanguage = DEFAULT_SETTINGS.useSteamLanguage,
    }

    local path = settings_path()
    if path and fs.exists(path) then
        local content = m_utils.read_file(path)
        local success, decoded = pcall(cjson.decode, content or "")
        if success and type(decoded) == "table" then
            if decoded.fastFetch ~= nil then values.fastFetch = decoded.fastFetch == true end
            if decoded.morrenusApiKey ~= nil then values.morrenusApiKey = tostring(decoded.morrenusApiKey or "") end
            if decoded.theme ~= nil then values.theme = tostring(decoded.theme or "original") end
            if decoded.useSteamLanguage ~= nil then values.useSteamLanguage = decoded.useSteamLanguage == true end
        end
    end

    saved_settings = values
    return values
end

local function save_settings(values)
    saved_settings = values
    local path = settings_path()
    if path then m_utils.write_file(path, encode(values)) end
end

local function work_directory(appid)
    local root = temp_root()
    if not root then return nil end

    local directory = fs.join(root, tostring(appid))
    if not fs.exists(directory) then fs.create_directories(directory) end
    return directory
end

local function state_path(appid)
    local directory = work_directory(appid)
    if not directory then return nil end
    return fs.join(directory, "state.json")
end

local function worker_state_path(appid)
    local directory = work_directory(appid)
    if not directory then return nil end
    return fs.join(directory, "worker.json")
end

local function log_path(appid)
    local directory = work_directory(appid)
    if not directory then return nil end
    return fs.join(directory, "download.log")
end

local function remove_work_directory(appid)
    local directory = work_directory(appid)
    if directory and fs.exists(directory) then pcall(fs.remove_all, directory) end
end

local function save_state(appid, state)
    states[appid] = state
    local path = state_path(appid)
    if path then m_utils.write_file(path, encode(state)) end
end

local function load_state(appid)
    local state = states[appid]
    if state then return state end

    local path = state_path(appid)
    if not path or not fs.exists(path) then return nil end

    local content = m_utils.read_file(path)
    local success, decoded = pcall(cjson.decode, content or "")
    if success and type(decoded) == "table" then
        states[appid] = decoded
        return decoded
    end
end

local function asset_json(path)
    local content = millennium.assets.read(path)
    if not content then return nil end

    local success, value = pcall(cjson.decode, content)
    if success then return value end
    logger:error("Failed to decode bundled asset " .. path)
end

local function source_url(source, appid, values)
    local url = source.url:gsub("<appid>", tostring(appid))
    return url:gsub("<moapikey>", values.morrenusApiKey or "")
end

local function source_status(source, appid, values)
    local needs_key = source.url:find("<moapikey>", 1, true) ~= nil and (values.morrenusApiKey or "") == ""
    local needs_login = source.needsLogin == true and auth.status().status ~= "signed_in"

    return {
        name = source.name,
        displayName = source.name,
        available = not needs_key and not needs_login,
        canDownload = not needs_key and not needs_login,
        needsKey = needs_key,
        needsLogin = source.needsLogin == true,
        locked = needs_key or needs_login,
        downloading = false,
        url = source_url(source, appid, values),
    }
end

local function public_state(state)
    local sources = {}
    for _, source in ipairs(state.sources or {}) do
        local downloading = (state.status == "downloading" or state.status == "extracting" or state.status == "installing") and state.selectedSource == source.name
        table.insert(sources, {
            name = source.name,
            displayName = source.displayName,
            available = source.available,
            canDownload = source.canDownload,
            needsKey = source.needsKey,
            needsLogin = source.needsLogin,
            locked = source.locked,
            downloading = downloading,
            indeterminate = downloading,
            progress = downloading and 100 or 0,
        })
    end

    local error = state.error
    if state.status == "failed" and state.logPath and state.logPath ~= "" then
        error = tostring(error or "Download failed") .. " - log: " ..tostring(state.logPath)
    end

    return {
        checking = state.status == "checking",
        sourcesLoaded = state.status ~= "checking",
        sources = sources,
        fastFetch = state.fastFetch == true,
        installed = state.status == "installed",
        installStatus = state.status == "installed" and "The game has been added successfully." or nil,
        error = state.status == "failed" and error or nil,
        logPath = state.logPath,
    }
end

local function powershell_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function start_download(appid, source)
    local steam = steam_path()
    local work = work_directory(appid)
    if not steam or not work then return false, "Could not find Steam installation" end

    local download_path = fs.join(work, tostring(appid) .. ".zip")
    local extract_path = fs.join(work, "extract")
    local state_file = worker_state_path(appid)
    local script_path = fs.join(work, "download.ps1")
    local lua_path = fs.join(steam, "config", "stplug-in", tostring(appid) .. ".lua")
    local depot_path = fs.join(steam, "depotcache")
    local log_file = log_path(appid)

    if not fs.exists(depot_path) then fs.create_directories(depot_path) end
    if fs.exists(extract_path) then fs.remove_all(extract_path) end
    if fs.exists(download_path) then fs.remove(download_path) end
    fs.create_directories(extract_path)

    if source.url:find('["\r\n\']') then
        logger:error("Rejected unsafe download URL for " .. tostring(appid) .. " from " .. tostring(source.name))
        return false, "Invalid download URL"
    end
    local download_command
    if source.needsLogin then
        local auth_script, message = auth.worker_path()
        if not auth_script then return false, message end
        download_command = ". " .. powershell_quote(auth_script) .. "\n    Invoke-LuaToolsDownload " .. powershell_quote(source.url) .. " " .. powershell_quote(download_path)
    else
        download_command = "Run-Native 'curl download' 'curl.exe' @('--fail', '--location', '--silent', '--show-error', '--user-agent', 'discord(dot)gg/luatools', '--output', " .. powershell_quote(download_path) .. ", " .. powershell_quote(source.url) .. ")"
    end
    m_utils.write_file(state_file, encode({ status = "downloading", logPath = log_file }))

    local script = string.format([==[$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$logFile = %s
function Write-State($status, $errorMessage = '') {
    $payload = @{ status = $status; error = $errorMessage; logPath = $logFile } | ConvertTo-Json -Compress
    Set-Content -LiteralPath %s -Value $payload -NoNewline
}
function Run-Native($name, $exe, [string[]]$arguments) {
    Add-Content -LiteralPath $logFile -Value ('[' + (Get-Date -Format o) + '] ' + $name)
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @arguments >> $logFile 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($exitCode -ne 0) { throw ($name + ' failed with exit code ' + $exitCode) }
}
try {
    Add-Content -LiteralPath $logFile -Value ('LuaTools download log for app %s from %s')
    Write-State 'downloading'
    %s
    $downloadPath = %s
    $extractPath = %s
    $stream = [IO.File]::OpenRead($downloadPath)
    try {
        $header = New-Object byte[] 4
        $count = $stream.Read($header, 0, 4)
    } finally { $stream.Dispose() }
    $isZip = $count -eq 4 -and $header[0] -eq 80 -and $header[1] -eq 75 -and (($header[2] -eq 3 -and $header[3] -eq 4) -or ($header[2] -eq 5 -and $header[3] -eq 6) -or ($header[2] -eq 7 -and $header[3] -eq 8))
    if ($isZip) {
        Write-State 'extracting'
        Run-Native 'extract archive' 'tar.exe' @('-xf', $downloadPath, '-C', $extractPath)
        $lua = Get-ChildItem -LiteralPath $extractPath -Recurse -Filter %s | Select-Object -First 1
        if (-not $lua) { $lua = Get-ChildItem -LiteralPath $extractPath -Recurse -Filter '*.lua' | Select-Object -First 1 }
        if (-not $lua) { throw 'Lua script not found in downloaded archive' }
        $content = Get-Content -LiteralPath $lua.FullName -Raw
    } else {
        $content = Get-Content -LiteralPath $downloadPath -Raw
        if ($content -notmatch '(?m)^\s*addappid\s*\(\s*\d+') { throw 'Download did not contain a ZIP archive or a Lua script' }
    }
    Write-State 'installing'
    $luaPath = %s
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $luaPath) -Force
    [IO.File]::WriteAllText($luaPath, ($content -replace '(?m)^\s*setManifestid\(', '-- setManifestid('), (New-Object Text.UTF8Encoding($false)))
    Get-ChildItem -LiteralPath $extractPath -Recurse -Filter '*.manifest' | Copy-Item -Destination %s -Force
    Write-State 'installed'
} catch {
    Add-Content -LiteralPath $logFile -Value ('[' + (Get-Date -Format o) + '] ERROR: ' + $_.Exception.Message)
    Add-Content -LiteralPath $logFile -Value $_.ScriptStackTrace
    Write-State 'failed' $_.Exception.Message
}
]==], powershell_quote(log_file), powershell_quote(state_file), tostring(appid), source.name, download_command, powershell_quote(download_path), powershell_quote(extract_path), powershell_quote(tostring(appid) .. ".lua"), powershell_quote(lua_path), powershell_quote(depot_path))

    m_utils.write_file(script_path, script)
    local _, status = m_utils.exec('start "" /b powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' .. script_path .. '" <NUL >NUL 2>&1')
    if status ~= 0 then return false, "Could not start download worker" end
    return true
end

function HasLuaToolsForApp(appid)
    local steam = steam_path()
    if not steam then return error_response("Could not find Steam installation") end

    local scripts = fs.join(steam, "config", "stplug-in")
    local id = tostring(appid)
    return encode({
        success = true,
        exists = fs.exists(fs.join(scripts, id .. ".lua")) or fs.exists(fs.join(scripts, id .. ".lua.disabled")),
    })
end

function DeleteLuaToolsForApp(appid)
    local steam = steam_path()
    if not steam then return error_response("Could not find Steam installation") end

    local scripts = fs.join(steam, "config", "stplug-in")
    local id = tostring(appid)
    for _, extension in ipairs({ ".lua", ".lua.disabled" }) do
        local path = fs.join(scripts, id .. extension)
        if fs.exists(path) then fs.remove(path) end
    end

    return encode({ success = true })
end

local function source_list(appid)
    local values = settings()
    local sources = {}
    for _, source in ipairs(SOURCES) do
        table.insert(sources, source_status(source, appid, values))
    end
    return sources
end

local function refresh_source_login(state)
    local signed_in = auth.status().status == "signed_in"
    for _, source in ipairs(state.sources or {}) do
        if source.needsLogin then
            source.locked = not signed_in
            source.available = signed_in
            source.canDownload = signed_in
        end
    end
end

local function select_source(state, after_name)
    refresh_source_login(state)
    local passed = after_name == nil
    for _, source in ipairs(state.sources or {}) do
        if passed and source.canDownload then return source end
        if source.name == after_name then passed = true end
    end
end

function StartLuaToolsAdd(appid)
    appid = tonumber(appid)
    if not appid then return error_response("Invalid app id") end

    local values = settings()
    local state = {
        status = "checking",
        sources = source_list(appid),
        fastFetch = values.fastFetch,
        logPath = log_path(appid),
    }
    save_state(appid, state)

    if values.fastFetch then
        local source = select_source(state)
        if source then
            local started, message = start_download(appid, source)
            if started then
                state.status = "downloading"
                state.selectedSource = source.name
            else
                state.status = "failed"
                state.error = message
            end
        else
            state.status = "failed"
            state.error = "No downloadable sources are available"
        end
    else
        state.status = "ready"
    end

    save_state(appid, state)
    return encode({ success = true })
end

function PickLuaToolsAddSource(appid, source_name)
    appid = tonumber(appid)
    local state = appid and load_state(appid)
    if not state then return error_response("No download is waiting for a source") end
    refresh_source_login(state)

    local source
    for _, candidate in ipairs(state.sources or {}) do
        if candidate.name == source_name then source = candidate break end
    end
    if not source or not source.canDownload then return error_response("Selected source is unavailable") end

    local started, message = start_download(appid, source)
    if not started then
        state.status = "failed"
        state.error = message
        save_state(appid, state)
        return error_response(message)
    end

    state.status = "downloading"
    state.selectedSource = source.name
    state.logPath = log_path(appid)
    save_state(appid, state)
    return encode({ success = true })
end

function GetLuaToolsAddStatus(appid)
    appid = tonumber(appid)
    local state = appid and load_state(appid)
    if not state then return encode({ success = true, sources = {} }) end

    local path = worker_state_path(appid)
    if path and fs.exists(path) then
        local content = m_utils.read_file(path)
        local success, update = pcall(cjson.decode, content or "")
        if success and type(update) == "table" and update.status then
            state.status = update.status
            state.error = update.error
            state.logPath = update.logPath or state.logPath
            if update.status == "installed" then
                states[appid] = state
                remove_work_directory(appid)
            else
                if update.status == "failed" then
                    logger:error("LuaTools install failed for " .. tostring(appid) .. " from " .. tostring(state.selectedSource) .. ": " .. tostring(update.error or "unknown error"))
                    local next_source = state.fastFetch and not state.cancelled and select_source(state, state.selectedSource)
                    if next_source and start_download(appid, next_source) then
                        state.status = "downloading"
                        state.error = nil
                        state.selectedSource = next_source.name
                    end
                end
                save_state(appid, state)
            end
        end
    end

    refresh_source_login(state)
    return encode(public_state(state))
end

function GetAddViaLuaToolsStatus(appid)
    return GetLuaToolsAddStatus(appid)
end

function CancelAddViaLuaTools(appid)
    appid = tonumber(appid)
    if appid then
        local state = load_state(appid)
        if state then
            state.status = "failed"
            state.error = "Cancelled"
            state.cancelled = true
            save_state(appid, state)
        end
    end
    return encode({ success = true })
end

function CheckApisForApp(appid)
    appid = tonumber(appid)
    if not appid then return error_response("Invalid app id") end

    return encode({
        success = true,
        results = source_list(appid),
    })
end

function StartAddViaLuaToolsFromUrl(appid, _, source)
    appid = tonumber(appid)
    if not source and type(_) == "string" and _:match("^https?://") then source = _ end
    if not appid or type(source) ~= "string" or not source:match("^https?://") then return error_response("Invalid download request") end

    local state = {
        status = "ready",
        sources = {
            {
                name = "Direct download",
                displayName = "Direct download",
                available = true,
                canDownload = true,
                url = source,
            },
        },
        logPath = log_path(appid),
    }
    save_state(appid, state)
    return PickLuaToolsAddSource(appid, "Direct download")
end

function OpenExternalUrl(url)
    if type(url) ~= "string" or not url:match("^https?://") or url:find('["\r\n]') then return error_response("Invalid URL") end
    m_utils.exec('start "" "' .. url .. '"')
    return encode({ success = true })
end

function GetThemes()
    return encode({
        success = true,
        themes = asset_json("public/themes/themes.json") or {},
    })
end

function GetIconDataUrl()
    local icon = millennium.assets.read("public/luatools-icon.png")
    if not icon then return error_response("LuaTools icon is unavailable") end

    return encode({
        success = true,
        dataUrl = "data:image/png;base64," .. base64_encode(icon),
    })
end

function GetSettingsConfig()
    local values = settings()
    return encode({
        success = true,
        schemaVersion = 1,
        schema = {},
        values = {
            general = values,
        },
        language = "en",
        locales = {},
        translations = {},
    })
end

function ApplySettingsChanges(first, second)
    local changes_json = second or first
    local success, changes = pcall(cjson.decode, tostring(changes_json or "{}"))
    if not success or type(changes) ~= "table" then return error_response("Invalid settings payload") end

    local values = settings()
    if changes.fastFetch ~= nil then values.fastFetch = changes.fastFetch == true end
    if changes.morrenusApiKey ~= nil then values.morrenusApiKey = tostring(changes.morrenusApiKey or "") end
    if changes.theme ~= nil then values.theme = tostring(changes.theme or "original") end
    if changes.useSteamLanguage ~= nil then values.useSteamLanguage = changes.useSteamLanguage == true end
    save_settings(values)

    return encode({
        success = true,
        values = {
            general = values,
        },
    })
end

function GetTranslations(_, language)
    return encode({
        success = true,
        language = type(language) == "string" and language or "en",
        locales = {},
        strings = {},
    })
end

function GetGamesDatabase()
    return encode({
        success = true,
        database = {},
    })
end

function CheckForFixes()
    return encode({
        success = true,
        hasFix = false,
        fixes = {},
    })
end

function CheckForUpdatesNow()
    return encode({ success = false, error = "Standalone updates are installed through Millennium." })
end

function ReadLoadedApps()
    return encode({ success = true, apps = {} })
end

function DismissLoadedApps()
    return encode({ success = true })
end

function GetLuaToolsAuthStatus()
    return encode(auth.status())
end

function SignInLuaTools()
    local success, message = auth.start("SignIn")
    return encode({ success = success, error = message })
end

function SignOutLuaTools()
    local success, message = auth.start("SignOut")
    return encode({ success = success, error = message })
end

local function on_load()
    local success, message = auth.start("Initialize")
    if not success then logger:error(message) end
    millennium.ready()
end

return {
    on_load = on_load,
}
