-- trace_flag_read.lua   (§57 follow-up: who reads the flag on respawn?)
--
-- "Find out what accesses" on a granted node's +0x18 during a death gave
-- exactly ONE instruction, hit ONCE:
--
--     MirrorsEdgeCatalyst.exe+39DA8DD   mov eax,[rax+18]
--
-- That is the generic flag-value getter -- RAX is the hashmap node, +0x18 is
-- the value field from the §56 layout. It is shared by every flag lookup in
-- the game, so the instruction itself tells us nothing. WHO CALLED IT does:
-- the caller during a respawn is the routine that rebuilds the player's
-- ability set, and that is what the AP client wants to call directly so a
-- player never has to die to receive an item.
--
-- At a mid-function instruction [RSP] is NOT reliably the return address, so
-- instead of guessing a frame layout this walks the raw stack and reports
-- every qword that points into the module. That over-reports (stale slots from
-- earlier calls linger), but the REAL call chain is the set of addresses that
-- shows up on EVERY hit, which the summary makes obvious.
--
-- FILTER: only hits where the node being read is our target are logged, so the
-- constant background flag traffic is discarded before it floods anything.
--
-- SETUP
--   1. Run flag_hashmap.lua read-only, note the node address printed for
--      Unlocks_MoveEnemyBack, and put it in TARGET_NODE below. (It changes
--      every game restart -- a stale value means zero hits.)
--   2. Ctrl+G to MirrorsEdgeCatalyst.exe+39DA8DD, F5 to set a breakpoint there.
--   3. Ctrl+Alt+L, paste this whole file, Execute Script.
--   4. Run in-game for ~10 seconds WITHOUT dying, then:  mark("idle baseline")
--   5. Die / restart from checkpoint.
--   6. Once you have respawned:  mark("after respawn")   then   sum()
--   7. Send the whole output back.
--
-- If step 4 produces hits, the flag is also polled during normal play, and the
-- respawn caller is whichever frame appears ONLY after the death mark.

local MODULE     = "MirrorsEdgeCatalyst.exe"
local TARGET_RVA = 0x39DA8DD

TARGET_NODE = 0x25B6CCC0   -- Unlocks_MoveEnemyBack node. RE-READ IT FIRST.
TARGET_HASH = 0x67800619   -- verified against [node+0x00] as a sanity check
DEPTH       = 40           -- stack qwords to scan (40 * 8 = 320 bytes)
MAXDETAIL   = 60

local BASE = getAddress(MODULE)
local BP   = BASE + TARGET_RVA

nhits, ndetail = 0, 0
frames = {}      -- [rvaString] = how many hits had this address on the stack
chains = {}      -- [chainString] = count
marks  = {}

local function rva(a)
  if a == nil then return nil end
  if a >= BASE and a < BASE + 0x10000000 then
    return string.format("+%X", a - BASE)
  end
  return nil
end

function mark(txt)
  table.insert(marks, { n = nhits, t = txt })
  print(string.format(">>> MARK at hit %d: %s", nhits, txt))
end

function clr()
  nhits, ndetail = 0, 0
  frames, chains, marks = {}, {}, {}
  print("cleared.")
end

function sum()
  print("")
  print("================ SUMMARY ================")
  print(string.format("hits on the target flag: %d", nhits))
  for _, m in ipairs(marks) do
    print(string.format("  mark at hit %-5d %s", m.n, m.t))
  end

  print("")
  print("-- module addresses seen on the stack, by how many hits --")
  print("   (an address present on EVERY hit is part of the real call chain;")
  print("    low counts are stale stack slots and can be ignored)")
  local keys = {}
  for k in pairs(frames) do table.insert(keys, k) end
  table.sort(keys, function(a, b) return frames[a] > frames[b] end)
  for i, k in ipairs(keys) do
    if i > 40 then print(string.format("   ... and %d more", #keys - 40)) break end
    print(string.format("   %-14s %d/%d hits", k, frames[k], nhits))
  end

  print("")
  print("-- distinct chains (first 8 module addresses, innermost first) --")
  local ck = {}
  for k in pairs(chains) do table.insert(ck, k) end
  table.sort(ck, function(a, b) return chains[a] > chains[b] end)
  for i, k in ipairs(ck) do
    if i > 10 then print(string.format("   ... and %d more distinct chain(s)", #ck - 10)) break end
    print(string.format("   x%-4d %s", chains[k], k))
  end
  print("=========================================")
end

function debugger_onBreakpoint()
  if RIP ~= BP then return 0 end

  -- only our flag: RAX is the node being read
  if RAX ~= TARGET_NODE then return 1 end

  -- sanity: the node's hash field must match, or TARGET_NODE is stale
  local h = readInteger(TARGET_NODE)
  if h ~= nil and h < 0 then h = h + 0x100000000 end
  if h ~= TARGET_HASH then
    print("!! node hash mismatch -- TARGET_NODE is stale, re-run flag_hashmap.lua")
    return 1
  end

  nhits = nhits + 1

  local chain, seen = {}, {}
  for i = 0, DEPTH - 1 do
    local q = readQword(RSP + i * 8)
    local r = rva(q)
    if r ~= nil and not seen[r] then
      seen[r] = true
      table.insert(chain, r)
      frames[r] = (frames[r] or 0) + 1
    end
  end

  local short = table.concat(chain, " < ", 1, math.min(#chain, 8))
  chains[short] = (chains[short] or 0) + 1

  if ndetail < MAXDETAIL then
    ndetail = ndetail + 1
    print(string.format("#%-4d %s", nhits, short))
  end

  return 1   -- auto-continue
end

print(string.format("armed on %s+%X (absolute %X)", MODULE, TARGET_RVA, BP))
print(string.format("filtering on node %X (hash %08X)", TARGET_NODE, TARGET_HASH))
print('Idle ~10s, then mark("idle baseline"), then DIE, then mark("after respawn"), then sum()')
