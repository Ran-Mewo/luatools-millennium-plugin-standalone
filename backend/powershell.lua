local millennium = require("millennium")
local fs = require("fs")
local utils = require("utils")

local powershell = {}
local worker_paths = {}

function powershell.quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

function powershell.data_directory()
    local root = utils.getenv("LOCALAPPDATA")
    if not root or root == "" then return nil end
    return fs.join(root, "LuaToolsPlugin")
end

function powershell.worker_script(name)
    if worker_paths[name] then return worker_paths[name] end
    local root = powershell.data_directory()
    if not root then return nil, "Could not find local application data" end
    if not fs.exists(root) then fs.create_directories(root) end

    local script = millennium.assets.read("backend/" .. name)
    if not script then return nil, "LuaTools worker " .. name .. " is unavailable" end
    local path = fs.join(root, name)
    if not utils.write_file(path, script) then return nil, "Could not write LuaTools worker " .. name end
    worker_paths[name] = path
    return path
end

-- utils.exec waits until every process holding its output pipe exits, and cmd's `start` hands that pipe to the child.
-- Start-Process goes through ShellExecute, which hands over no handles, so this returns as soon as the worker is launched.
function powershell.start_hidden(script_path, arguments)
    local argument_list = "'-NoProfile -ExecutionPolicy Bypass -File ' + [char]34 + " .. powershell.quote(script_path) .. " + [char]34"
    if arguments then argument_list = argument_list .. " + ' " .. arguments .. "'" end
    local _, status = utils.exec('powershell.exe -NoProfile -NonInteractive -Command "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (' .. argument_list .. ')" <NUL >NUL 2>&1')
    return status == 0
end

return powershell
