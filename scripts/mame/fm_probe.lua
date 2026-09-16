-- Does an FG-3 game use the OPL4's FM synthesis, or only its PCM?
--
-- The Z80 reaches the chip through I/O ports 0x40-0x45, and
-- ymfm::ymf278b::write() maps those offsets as:
--
--     0  FM address, bank 0        1  FM data
--     2  FM address, bank 1        3  FM data      (address | 0x100)
--     4  PCM address              5  PCM data
--
-- A key-on is a write to FM register 0xB0-0xB8 (or 0x1B0-0x1B8) with bit 5
-- set; rhythm-mode key-ons are register 0xBD bits 0-4. Key-ons are counted
-- apart from other FM writes, since a driver may initialise FM and never play.
--
-- Environment:
--   FUUKI_OUT     directory for the report
--   FUUKI_FRAMES  how many frames to observe (60 = 1 second)
--   FUUKI_TAG     name for the report file

local OUT    = os.getenv("FUUKI_OUT")    or "D:/Arcade-Fuuki_MiSTer/debug/fm_probe"
local FRAMES = tonumber(os.getenv("FUUKI_FRAMES") or "3600")
local TAG    = os.getenv("FUUKI_TAG")    or "fg3"

local mach = manager.machine
local cpu  = mach.devices[":soundcpu"]
local scr  = mach.screens[":screen"]

if cpu == nil then
    print("FMPROBE  FATAL: no :soundcpu device")
    mach:exit()
    return
end

-- The driver's map.global_mask(0xff) makes the I/O space 8 bits wide, so a
-- tap over 0x0000-0xFFFF is rejected ("end address is outside of the global
-- address mask") with a modal dialog, which hangs a -video none run silently.
local io_space = cpu.spaces["io"]
if io_space == nil then
    local names = {}
    for n, _ in pairs(cpu.spaces) do names[#names+1] = n end
    print("FMPROBE  FATAL: no io space; have: " .. table.concat(names, ", "))
    mach:exit()
    return
end

local fm_addr   = { [0] = 0, [1] = 0 }   -- last address written, per bank
local pcm_addr  = 0

local n_fm_data   = 0     -- writes to an FM data port
local n_pcm_data  = 0     -- writes to a PCM data port
local n_keyon     = 0     -- FM channel key-ON events (bit 5 set)
local n_keyoff    = 0     -- FM channel key-OFF writes
local n_rhythm_on = 0
local newflag     = -1    -- last value written to register 0x105 (OPL3 NEW)

local fm_regs_seen = {}   -- set of FM registers ever written
local fm_regs_last = {}   -- last value written to each; decides audibility
local keyon_ch     = {}   -- key-on count per channel
local keyon_bucket = {}   -- key-ons per 600-frame bucket, to separate a
                          -- one-off boot sequence from ongoing music
local fm_first_frame, fm_keyon_first_frame

local function note_fm_write(reg, data)
    n_fm_data = n_fm_data + 1
    fm_regs_seen[reg] = (fm_regs_seen[reg] or 0) + 1
    fm_regs_last[reg] = data
    if fm_first_frame == nil then fm_first_frame = scr:frame_number() end

    if reg == 0x105 then newflag = data end

    local lo = reg & 0xFF
    if lo >= 0xB0 and lo <= 0xB8 then
        local ch = (reg >= 0x100 and 9 or 0) + (lo - 0xB0)
        if (data & 0x20) ~= 0 then
            n_keyon = n_keyon + 1
            keyon_ch[ch] = (keyon_ch[ch] or 0) + 1
            local b = math.floor(scr:frame_number() / 600)
            keyon_bucket[b] = (keyon_bucket[b] or 0) + 1
            if fm_keyon_first_frame == nil then
                fm_keyon_first_frame = scr:frame_number()
            end
        else
            n_keyoff = n_keyoff + 1
        end
    elseif lo == 0xBD and (data & 0x1F) ~= 0 then
        -- Rhythm mode: bits 0-4 key on BD/SD/TOM/TC/HH.
        n_rhythm_on = n_rhythm_on + 1
    end
end

_G.__fm_tap = io_space:install_write_tap(0x40, 0x45, "opl4", function(offset, data, mask)
    local port = offset & 0xFF
    if port >= 0x40 and port <= 0x45 then
        local sel = port - 0x40
        local d = data & 0xFF
        if     sel == 0 then fm_addr[0] = d
        elseif sel == 2 then fm_addr[1] = d | 0x100
        elseif sel == 1 then note_fm_write(fm_addr[0], d)
        elseif sel == 3 then note_fm_write(fm_addr[1], d)
        elseif sel == 4 then pcm_addr = d
        elseif sel == 5 then n_pcm_data = n_pcm_data + 1
        end
    end
    return data
end)

local done = false
_G.__fm_notifier = emu.add_machine_frame_notifier(function()
    if done then return end
    if scr:frame_number() < FRAMES then return end
    done = true

    local path = string.format("%s/%s_fm.txt", OUT, TAG)
    local f = assert(io.open(path, "w"))
    local function say(s)
        print("FMPROBE  " .. s)
        f:write(s .. "\n")
    end

    say(string.format("system            %s (%s)", mach.system.name, mach.system.description))
    say(string.format("frames observed   %d", scr:frame_number()))
    say("")
    say(string.format("FM data writes    %d", n_fm_data))
    say(string.format("PCM data writes   %d", n_pcm_data))
    say(string.format("FM KEY-ON events  %d   <-- the deciding number", n_keyon))
    say(string.format("FM key-off writes %d", n_keyoff))
    say(string.format("FM rhythm key-ons %d", n_rhythm_on))
    say(string.format("OPL3 NEW reg 0x105 last value  %s",
        newflag < 0 and "never written" or string.format("0x%02X", newflag)))
    say(string.format("first FM write at frame        %s",
        fm_first_frame and tostring(fm_first_frame) or "never"))
    say(string.format("first FM key-on at frame       %s",
        fm_keyon_first_frame and tostring(fm_keyon_first_frame) or "never"))

    local chs = {}
    for ch, n in pairs(keyon_ch) do chs[#chs+1] = string.format("ch%d:%d", ch, n) end
    table.sort(chs)
    say("key-ons per channel            " .. (#chs > 0 and table.concat(chs, " ") or "none"))

    -- Carrier Total Level: bits 5-0 of 0x40+op; 0x3F is silence. Channel n's
    -- operators are (n, n+3) within each group of three: channels 0-2 use ops
    -- 0x00-0x05, channels 6-8 use 0x08-0x0D.
    say("")
    say("Total Level registers (last value; TL 0x3F = silent):")
    local any_tl = false
    for base = 0, 1 do
        for op = 0, 0x15 do
            local reg = base * 0x100 + 0x40 + op
            local v = fm_regs_last[reg]
            if v ~= nil then
                any_tl = true
                say(string.format("  reg %03X = %02X   TL=%2d %s",
                    reg, v, v & 0x3F,
                    (v & 0x3F) == 0x3F and "(max attenuation -- silent)" or ""))
            end
        end
    end
    if not any_tl then say("  none written at all") end

    -- Connection and 4-op mode decide which operator is the carrier, which the
    -- TL table needs:
    --   0x104 bits 0-5 put channel pairs (0+3, 1+4, 2+5, 9+12, ...) into
    --                  4-operator mode
    --   0xC0+n bit 0   CNT: 0 = FM (op2 is the carrier), 1 = AM (both sound)
    --          bits 3-1 feedback
    say("")
    say("connection / 4-op mode (last values):")
    say(string.format("  reg 104 = %s   (4-op enable, bits 0-5)",
        fm_regs_last[0x104] and string.format("%02X", fm_regs_last[0x104]) or "never written"))
    for base = 0, 1 do
        for ch = 0, 8 do
            local reg = base * 0x100 + 0xC0 + ch
            local v = fm_regs_last[reg]
            if v ~= nil then
                say(string.format("  reg %03X = %02X   CNT=%d (%s)  FB=%d  out=%s%s",
                    reg, v, v & 1, (v & 1) == 1 and "AM/additive" or "FM/serial",
                    (v >> 1) & 7,
                    (v & 0x10) ~= 0 and "L" or "-", (v & 0x20) ~= 0 and "R" or "-"))
            end
        end
    end

    say("")
    say("key-ons per 10-second bucket (frame/600):")
    local bl = ""
    for b = 0, math.floor(FRAMES / 600) do
        bl = bl .. string.format("%d:%d ", b, keyon_bucket[b] or 0)
    end
    say("  " .. bl)

    -- Which FM registers were written, and how often.
    local regs = {}
    for r, _ in pairs(fm_regs_seen) do regs[#regs+1] = r end
    table.sort(regs)
    say(string.format("distinct FM registers written  %d", #regs))
    local line = ""
    for _, r in ipairs(regs) do
        line = line .. string.format("%03X:%d ", r, fm_regs_seen[r])
        if #line > 70 then say("  " .. line); line = "" end
    end
    if #line > 0 then say("  " .. line) end

    f:close()
    print("FMPROBE  wrote " .. path)
    mach:exit()
end)
