-- Log the video registers at the end of each of several consecutive frames.
-- Decides whether a capture's dumps can be trusted against its own snapshot:
-- if a scrolling layer's registers change every frame, then any skew between
-- when the image is rendered and when the registers are read shows up as a
-- displaced layer.
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local scr  = manager.machine.screens[":screen"]
local out  = assert(io.open(os.getenv("FUUKI_OUT") or "D:/Arcade-Fuuki_MiSTer/debug/vregs_frames.txt", "w"))
local first = tonumber(os.getenv("FUUKI_FRAME") or "1100")
local n = 0
_G.__k = emu.add_machine_frame_notifier(function()
    local f = scr:frame_number()
    if f < first then return end
    n = n + 1
    local t = {}
    for i = 0, 15 do t[#t+1] = string.format("%04X", prog:read_u16(0x8c0000 + i*2)) end
    out:write(string.format("frame %d: %s\n", f, table.concat(t, " ")))
    if n >= 6 then out:close(); print("VREGFRAMES done"); manager.machine:exit() end
end)
