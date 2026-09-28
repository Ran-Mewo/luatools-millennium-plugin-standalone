local millennium = require("millennium")
local fs = require("fs")
local utils = require("utils")
local json = require("json")

local auth = {}
local script_path

local function directory()
    local root = utils.getenv("LOCALAPPDATA")
    if not root or root == "" then return nil end
    return fs.join(root, "LuaToolsPlugin")
end

function auth.worker_path()
    if script_path then return script_path end
    local root = directory()
    if not root then return nil, "Could not find local application data" end
    if not fs.exists(root) then fs.create_directories(root) end

    local script = millennium.assets.read("backend/auth.ps1")
    if not script then return nil, "LuaTools login worker is unavailable" end
    local path = fs.join(root, "auth.ps1")
    local written = utils.write_file(path, script)
    if not written then return nil, "Could not write LuaTools login worker" end
    script_path = path
    return path
end

function auth.status()
    local root = directory()
    local content = root and utils.read_file(fs.join(root, "status.json"))
    local success, status = pcall(json.decode, content or "")
    if not success or type(status) ~= "table" then return { status = "signed_out" } end
    if (status.status == "checking" or status.status == "waiting") and os.time() - (tonumber(status.updatedAt) or 0) > 360 then
        return { status = "error", error = "Sign-in timed out. Please try again." }
    end
    return {
        status = status.status,
        displayName = status.displayName,
        error = status.error,
    }
end

function auth.start(action)
    local path, message = auth.worker_path()
    if not path then return false, message end
    if action ~= "Initialize" and action ~= "SignIn" and action ~= "SignOut" then return false, "Invalid login action" end
    local _, status = utils.exec('start "" /b powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' .. path .. '" -Action ' .. action .. ' <NUL >NUL 2>&1')
    if status ~= 0 then return false, "Could not start LuaTools login worker" end
    return true
end

return auth
