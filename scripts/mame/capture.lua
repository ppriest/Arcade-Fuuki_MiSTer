-- Capture a reference frame from a running Fuuki game: every piece of video
-- state the RTL renders from, plus the screenshot MAME produced from it.
--
-- Driven by scripts/mame_capture.py -- see that file for usage. Parameters
-- arrive as environment variables because MAME gives an autoboot script no
-- argument vector of its own:
--
--   FUUKI_OUT     directory to write into (must already exist)
--   FUUKI_FRAME   frame number to capture at
--   FUUKI_BOARD   "fg2" or "fg3"
--   FUUKI_VREGLOG "1" to also log every video-register write, with the frame
--                 and the raster line in force when it happened
--
-- Everything is read through the CPU program space, so what lands in the file
-- is what the CPU would read -- device handlers and all -- rather than a
-- guess at where MAME keeps it internally.

local OUT   = os.getenv("FUUKI_OUT")   or "D:/Arcade-Fuuki_MiSTer/debug/capture"
local FRAME = tonumber(os.getenv("FUUKI_FRAME") or "600")
local BOARD = os.getenv("FUUKI_BOARD") or "fg2"
local VREGLOG = os.getenv("FUUKI_VREGLOG") == "1"

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local prog  = cpu.spaces["program"]
local scr   = mach.screens[":screen"]

-- Regions to dump. Address, length, name. The FG-3 extras are appended below.
local regions = {
    { 0x500000, 0x8000,  "vram"      },  -- 4 x 8 KB tilemap banks
    { 0x600000, 0x2000,  "spriteram" },  -- 1024 records x 4 words
    { 0x700000, 0x4000,  "palette"   },  -- 8192 x xRGB-555
    { 0x8c0000, 0x20,    "vregs"     },  -- scroll / offset / raster / flip
    { 0x8d0000, 0x4,     "unknown"   },
    { 0x8e0000, 0x2,     "priority"  },  -- layer order
    { 0x400000, 0x10000, "workram"   },
}
if BOARD == "fg3" then
    regions[#regions+1] = { 0x410000, 0x10000, "workram2" }
    regions[#regions+1] = { 0xa00000, 0x4,     "tilebank" }
end

local function dump(addr, len, name)
    local path = string.format("%s/%s_%s.bin", OUT, BOARD, name)
    local f = assert(io.open(path, "wb"))
    -- Read a word at a time: these are 16-bit devices, and byte reads through
    -- a word handler are not always the same thing.
    local buf = {}
    for i = 0, len - 2, 2 do
        local w = prog:read_u16(addr + i)
        buf[#buf+1] = string.char((w >> 8) & 0xFF, w & 0xFF)   -- big-endian
    end
    f:write(table.concat(buf))
    f:close()
    print(string.format("CAPTURE  %-10s %06X +%05X -> %s", name, addr, len, path))
end

-- Optional: log video-register writes as they happen, tagged with the frame
-- and with the raster-interrupt line currently programmed. That last column is
-- what makes the log reconstructable into a per-scanline picture -- register
-- 0x1c says which line the NEXT interrupt fires on, so a write logged with it
-- can be placed on the timeline.
local vreglog
if VREGLOG then
    vreglog = assert(io.open(string.format("%s/%s_vregs.log", OUT, BOARD), "w"))
    vreglog:write("# frame\taddr\tdata\traster_line_in_force\tpc\n")
    local tap = prog:install_write_tap(0x8c0000, 0x8effff, "vregs", function(offset, data, mask)
        local raster = prog:read_u16(0x8c001c)
        vreglog:write(string.format("%d\t%06X\t%04X\t%04X\t%08X\n",
            scr:frame_number(), offset, data & 0xFFFF, raster,
            cpu.state["PC"].value))
        return data
    end)
    _G.__fuuki_tap = tap   -- keep it alive; a collected tap stops firing
    print("CAPTURE  vreg write tap installed")
end

-- KEEP THE SUBSCRIPTION ALIVE. emu.add_machine_frame_notifier returns a
-- subscription object, and if it is dropped the garbage collector eventually
-- reclaims it and the callback silently STOPS FIRING. This is the same trap as
-- the write tap above, and it fails in a thoroughly misleading way: a capture
-- at frame 120 worked (the callback fired long before a collection happened)
-- while the identical capture at frame 1100 produced nothing at all, no error,
-- and MAME exited cleanly with status 0.
local done = false
_G.__fuuki_frame_notifier = emu.add_machine_frame_notifier(function()
    if done then return end
    local n = scr:frame_number()
    if n < FRAME then return end
    done = true

    print(string.format("CAPTURE  frame %d, board %s -> %s", n, BOARD, OUT))
    for _, r in ipairs(regions) do dump(r[1], r[2], r[3]) end

    -- The screenshot is as important as the dumps: it is the reference the
    -- RTL's own rendering of this exact state gets compared against.
    mach.video:snapshot()

    local f = assert(io.open(string.format("%s/%s_info.txt", OUT, BOARD), "w"))
    f:write(string.format("system      %s\n", mach.system.name))
    f:write(string.format("description %s\n", mach.system.description))
    f:write(string.format("frame       %d\n", n))
    f:write(string.format("screen      %dx%d refresh %f\n", scr.width, scr.height, scr.refresh))
    f:write(string.format("mame        %s\n", emu.app_version()))
    f:close()

    if vreglog then vreglog:close() end
    print("CAPTURE  done")
    mach:exit()
end)
