-- Log every write the Z80 makes to the OPL4, and insert a coin on cue.
--
-- The question this answers: what does the sound driver actually SEND for a
-- given sound? The RTL's PCM engine has been read against ymfm line by line
-- and matches it, and the same engine plays Psikyo's effects on hardware --
-- so if Fuuki's one-shot effects come out far quieter than its music, the
-- difference is in what the driver asks for, and that is a register sequence
-- to capture rather than a mechanism to guess.
--
-- Output: one line per OPL4 write, "frame 0 port value" (this MAME build has no
-- screen.vpos, so the second column is a placeholder), plus a KEYON line
-- for every PCM channel key-on carrying the channel's register state at that
-- instant (wave number, octave/fnum, TL and LD, pan/damp/lfo-reset/output).
-- The runner (scripts/opl4_log.py) decodes those against the wavetable
-- headers in opm.u6.
--
-- Environment (all set by the runner):
--   FUUKI_OUT          output directory
--   FUUKI_LOG_FROM     first frame to log
--   FUUKI_LOG_TO       last frame to log; the run exits here
--   FUUKI_COIN_FRAME   frame at which to insert a coin (0 = never)

local OUT   = os.getenv("FUUKI_OUT")        or "."
local FROM  = tonumber(os.getenv("FUUKI_LOG_FROM")   or "0")
local TO    = tonumber(os.getenv("FUUKI_LOG_TO")     or "3600")
local COIN  = tonumber(os.getenv("FUUKI_COIN_FRAME") or "0")

local mach = manager.machine
local cpu  = mach.devices[":soundcpu"]
local scr  = mach.screens[":screen"]

local log = assert(io.open(OUT .. "/opl4_writes.txt", "w"))
local function say(s) print("OPL4LOG  " .. s) end

if cpu == nil then say("FATAL: no :soundcpu"); mach:exit(); return end
local io_space = cpu.spaces["io"]
if io_space == nil then say("FATAL: no io space"); mach:exit(); return end

-- ---- find the coin input ----
-- Port and field names are the driver's; the first field called exactly
-- "Coin 1" is taken, or failing that the first whose name contains "Coin".
local coin_field, coin_desc
local function find_coin()
    local ok, err = pcall(function()
        local fallback, fdesc
        for ptag, port in pairs(mach.ioport.ports) do
            for fname, field in pairs(port.fields) do
                if fname == "Coin 1" then
                    coin_field, coin_desc = field, ptag .. " / " .. fname
                    return
                elseif fallback == nil and string.find(fname, "Coin") then
                    fallback, fdesc = field, ptag .. " / " .. fname
                end
            end
        end
        coin_field, coin_desc = fallback, fdesc
    end)
    if not ok then say("ioport walk failed: " .. tostring(err)) end
    say("coin input: " .. tostring(coin_desc))
end
find_coin()

-- ---- OPL4 write tap ----
local fm_addr  = { [0] = 0, [1] = 0 }
local pcm_addr = 0
local pcm_regs = {}
for i = 0, 255 do pcm_regs[i] = 0 end
local n_writes, n_keyon = 0, 0
local logging = false

local function keyon_line(ch)
    local wav  = pcm_regs[0x08 + ch] | ((pcm_regs[0x20 + ch] & 1) << 8)
    local fnum = ((pcm_regs[0x20 + ch] >> 1) & 0x7F) | ((pcm_regs[0x38 + ch] & 7) << 7)
    local oct  = (pcm_regs[0x38 + ch] >> 4) & 0xF
    if oct >= 8 then oct = oct - 16 end
    local rev  = (pcm_regs[0x38 + ch] >> 3) & 1
    local tl   = (pcm_regs[0x50 + ch] >> 1) & 0x7F
    local ld   = pcm_regs[0x50 + ch] & 1
    local k    = pcm_regs[0x68 + ch]
    local pan  = k & 0xF
    if pan >= 8 then pan = pan - 16 end
    return string.format(
        "KEYON ch=%2d wave=%3d oct=%2d fnum=%3d TL=%3d LD=%d pan=%2d damp=%d lforst=%d out=%d rev=%d  r80=%02X r98=%02X rB0=%02X rC8=%02X rE0=%02X",
        ch, wav, oct, fnum, tl, ld, pan, (k >> 6) & 1, (k >> 5) & 1, (k >> 4) & 1, rev,
        pcm_regs[0x80 + ch], pcm_regs[0x98 + ch], pcm_regs[0xB0 + ch],
        pcm_regs[0xC8 + ch], pcm_regs[0xE0 + ch])
end

_G.__opl4_tap = io_space:install_write_tap(0x40, 0x45, "opl4log", function(offset, data, mask)
    local port = offset & 0xFF
    if port >= 0x40 and port <= 0x45 then
        local sel = port - 0x40
        local d = data & 0xFF
        local fr = scr:frame_number()
        local line = ""
        if     sel == 0 then fm_addr[0] = d
        elseif sel == 2 then fm_addr[1] = d | 0x100
        elseif sel == 1 then line = string.format("FM  %03X=%02X", fm_addr[0], d)
        elseif sel == 3 then line = string.format("FM  %03X=%02X", fm_addr[1], d)
        elseif sel == 4 then pcm_addr = d
        elseif sel == 5 then
            local was = pcm_regs[pcm_addr]
            pcm_regs[pcm_addr] = d
            line = string.format("PCM %02X=%02X", pcm_addr, d)
            if pcm_addr >= 0x68 and pcm_addr <= 0x7F then
                local ch = pcm_addr - 0x68
                if (d & 0x80) ~= 0 and (was & 0x80) == 0 then
                    n_keyon = n_keyon + 1
                    line = line .. "  " .. keyon_line(ch)
                elseif (d & 0x80) == 0 and (was & 0x80) ~= 0 then
                    line = line .. string.format("  KEYOFF ch=%2d", ch)
                end
            end
        end
        if logging and line ~= "" then
            n_writes = n_writes + 1
            log:write(string.format("%6d %3d  %s\n", fr, 0, line))
        end
    end
    return data
end)

-- ---- frame driver: logging window, the coin, the exit ----
local coin_state = 0
local done = false
_G.__opl4_notifier = emu.add_machine_frame_notifier(function()
    if done then return end
    local fr = scr:frame_number()
    if fr >= FROM and not logging then
        logging = true
        say(string.format("logging from frame %d", fr))
    end
    if COIN > 0 and coin_field ~= nil then
        if fr == COIN and coin_state == 0 then
            local ok, err = pcall(function() coin_field:set_value(1) end)
            say(string.format("coin DOWN at frame %d (%s)", fr, ok and "ok" or tostring(err)))
            log:write(string.format("%6d %3d  COIN down\n", fr, 0))
            coin_state = 1
        elseif fr == COIN + 4 and coin_state == 1 then
            local ok, err = pcall(function() coin_field:clear_value() end)
            if not ok then pcall(function() coin_field:set_value(0) end) end
            say(string.format("coin UP at frame %d", fr))
            log:write(string.format("%6d %3d  COIN up\n", fr, 0))
            coin_state = 2
        end
    end
    if fr >= TO then
        done = true
        log:close()
        say(string.format("done: %d writes logged, %d PCM key-ons", n_writes, n_keyon))
        mach:exit()
    end
end)
