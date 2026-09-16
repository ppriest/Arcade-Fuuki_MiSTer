-- Bootstrap that makes Lua failures VISIBLE to the calling script.
--
-- MAME reports a broken autoboot script with a modal dialog, which leaves a
-- headless run sitting with no output. This writes the error to
-- lua_error.txt for the Python runner:
--
--   syntax errors    loadfile() returns nil plus a message; pcall cannot
--                    catch these.
--   runtime errors   pcall around the call. Errors inside a frame notifier
--                    do not reach here; the notifier must pcall itself.
--
-- Point -autoboot_script at THIS file and pass the real script in FUUKI_SCRIPT.

local OUT    = os.getenv("FUUKI_OUT")    or "."
local SCRIPT = os.getenv("FUUKI_SCRIPT")

local function record(kind, msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then
        f:write(kind .. ": " .. tostring(msg) .. "\n")
        f:close()
    end
    print("LUAFAIL " .. kind .. ": " .. tostring(msg))
end

if not SCRIPT then
    record("config", "FUUKI_SCRIPT is not set")
    manager.machine:exit()
    return
end

local chunk, lerr = loadfile(SCRIPT)
if not chunk then
    record("syntax", lerr)
    manager.machine:exit()
    return
end

local ok, rerr = pcall(chunk)
if not ok then
    record("runtime", rerr)
    manager.machine:exit()
end
