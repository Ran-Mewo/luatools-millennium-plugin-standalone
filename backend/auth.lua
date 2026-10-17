local fs = require("fs")
local utils = require("utils")
local json = require("json")
local powershell = require("powershell")

local auth = {}

function auth.worker_path()
    local network_script, message = powershell.worker_script("network.ps1")
    if not network_script then return nil, message end
    return powershell.worker_script("auth.ps1")
end

function auth.status()
    local root = powershell.data_directory()
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
    if not powershell.start_hidden(path, "-Action " .. action) then return false, "Could not start LuaTools login worker" end
    return true
end

return auth
