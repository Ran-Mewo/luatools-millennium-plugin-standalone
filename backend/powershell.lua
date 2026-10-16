local utils = require("utils")

local powershell = {}

function powershell.quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
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
