-- analyze_chain.lua   (§58: identify the respawn ability-rebuild call chain)
--
-- trace_flag_read.lua caught the respawn read of Unlocks_MoveEnemyBack. Zero
-- hits while playing normally, exactly ONE hit during the death/respawn, with
-- this stack (innermost first):
--
--   +3A77E14 < +31250EE < +1A5BDB8 < +3149001 < +33542D6 < +33604F0 < +337442E
--
-- Those are RETURN addresses: each points just after a `call`. This script, for
-- each one, does two things:
--
--   1. Walks BACKWARDS to the function's start. MSVC pads between functions
--      with 0xCC (int 3), so a run of CC followed by code is a function
--      boundary. That start address is what an AP client would call or hook.
--   2. Disassembles forward from that start to the return address, and prints
--      the last few instructions before it -- which includes the `call` that
--      produced this frame, naming the function that was entered.
--
-- Read-only. No breakpoints needed; disable the +39DA8DD one first so the game
-- runs at normal speed while this runs.
--
-- Caveats worth keeping in mind when reading the output:
--   * CC-padding is a heuristic. A function that starts right after a jump
--     table, or one the linker merged, can be missed -- if "start" looks
--     absurdly far from the return address (many KB), distrust that row.
--   * Some of these frames may be stale stack slots rather than real callers.
--     Only one hit was captured, so we can't yet tell them apart by frequency.
--     The disassembly is what settles it: a frame whose preceding instruction
--     is a real `call` is a genuine caller.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)

local CHAIN = {
  0x3A77E14,   -- innermost: called the flag getter at +39DA8DD
  0x31250EE,
  0x1A5BDB8,
  0x3149001,
  0x33542D6,
  0x33604F0,
  0x337442E,   -- outermost
}

local MAXBACK  = 0x4000   -- how far back to look for the CC padding
local TAILINST = 6        -- instructions to show before the return address

local function rva(a)
  if a >= BASE and a < BASE + 0x10000000 then
    return string.format("+%X", a - BASE)
  end
  return string.format("%X", a)
end

-- find the start of the function containing `addr` by looking for int3 padding
local function findStart(addr)
  local run = 0
  for i = 0, MAXBACK do
    local a = addr - i
    local b = readBytes(a, 1, false)
    if b == nil then return nil, "unreadable" end
    if b == 0xCC then
      run = run + 1
      if run >= 2 then
        return a + run, nil   -- first byte after the padding run
      end
    else
      run = 0
    end
  end
  return nil, "no padding found within range"
end

print(string.format("module base %X\n", BASE))

for idx, r in ipairs(CHAIN) do
  local ret = BASE + r
  print(string.format("================ frame %d: return address %s ================", idx, rva(ret)))

  local start, err = findStart(ret)
  if start == nil then
    print("   could not locate function start: " .. tostring(err))
  else
    print(string.format("   function start: %s   (return is %d bytes in)", rva(start), ret - start))

    -- walk forward from the start, keeping the last few instruction addresses
    local addrs = {}
    local a = start
    local guard = 0
    while a < ret and guard < 20000 do
      table.insert(addrs, a)
      local sz = getInstructionSize(a)
      if sz == nil or sz == 0 then
        print("   disassembly desynced -- stopping walk")
        break
      end
      a = a + sz
      guard = guard + 1
    end

    if a ~= ret then
      print(string.format("   !! walk landed on %s, not the return address -- the function", rva(a)))
      print("      start is probably wrong (bad padding guess). Treat this row with suspicion.")
    end

    print("   instructions leading up to the return address:")
    local first = math.max(1, #addrs - TAILINST + 1)
    for i = first, #addrs do
      print(string.format("     %-12s %s", rva(addrs[i]), disassemble(addrs[i])))
    end
    print(string.format("     %-12s %s   <== execution resumes here", rva(ret), disassemble(ret)))
  end
  print("")
end

print("Done -- send the whole output back.")
