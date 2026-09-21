-- log_item_checks.lua   (§59: which entities check which flags on respawn?)
--
-- CORRECTION TO §58: the breakpoint at +3A77DB3 never fired because +3A77DB3 is
-- not a real function start. +31250A0 and +3354280 came from actual CALL
-- targets; +3A77DB3 is only reached through `call [r14+08]`, so its "start" was
-- the CC-padding guess -- which had already been shown to land a few bytes off.
-- It sat on padding that never executes.
--
-- This breaks instead at +3A77E14, which is KNOWN to execute: it was the
-- captured return address. It is the instruction right after
--
--     mov rdx,[rbx+80]        ; flag definition, cached on the entity
--     mov rcx,[14257C9D8]     ; the §56 flag table
--     call +39DA880           ; read the flag value
--   > +3A77E14  mov r8b,01    ; <-- we stop here
--
-- so at this instant:
--     RBX          = the entity that is asking
--     [RBX+0x80]   = the flag definition it asked about
--     EAX          = the value it got back  (the getter returns eax=[node+18])
--
-- The flag definition pointer is the same one stored at node+0x08 in the
-- hashmap, so we resolve it back to a hash by walking the table once at load.
--
-- WHAT §58's +3354280/+31250A0 LOG SHOWED (why this is the right question):
-- both fire ONLY on respawn (0 idle, 43 during death), but +3354280 ran on 12
-- distinct objects of one class and +31250A0 is a generic dispatcher used by
-- several classes. That is not "one function rebuilds the ability list" -- it is
-- the player's logic entities being re-created, each checking its own flag as
-- it initialises. This script names those entities and their flags.
--
-- SETUP
--   1. REMOVE the old breakpoints (+31250A0, +3354280, +3A77DB3) -- F5 each.
--   2. Ctrl+G to MirrorsEdgeCatalyst.exe+3A77E14, F5.
--   3. Paste this, Execute. It prints how many table nodes it indexed.
--   4. Idle ~10s   ->  mark("idle baseline")
--   5. Die / checkpoint restart
--   6. Respawned   ->  mark("after respawn")  then  sum()
--   7. F5 the breakpoint off, send the whole output.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)
local BP     = BASE + 0x3A77E14

MAXDETAIL = 120

-- names we already know; everything else is printed as a hash for offline decoding
local KNOWN = {
  [0x67800619] = "Unlocks_MoveEnemyBack",
  [0xF139B4B3] = "Unlocks_DoubleWallrun",
  [0x6F18BEF0] = "Unlocks_FastClimb",
  [0x2B48D119] = "Unlocks_Shift",
  [0x427FB289] = "Unlocks_ExtendedSlide",
  [0x2C9CC1D5] = "Unlocks_Focus",
  [0x17EEE7F5] = "Unlocks_FlowAttack_Special_PowerAttack",
  [0x848D8855] = "Unlocks_IncreasedHealth0",
  [0x848D8854] = "Unlocks_IncreasedHealth1",
  [0x848D8857] = "Unlocks_IncreasedHealth2",
  [0x848D8856] = "Unlocks_IncreasedHealth3",
  [0x848D8851] = "Unlocks_IncreasedHealth4",
}

local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

local function rva(a)
  if a == nil then return "nil" end
  if a >= BASE and a < BASE + 0x10000000 then
    return string.format("+%X", a - BASE)
  end
  return string.format("%X", a)
end

-- index the flag table: definition pointer (node+0x08) -> hash (node+0x00)
defToHash = {}
local tbl = readQword(BASE + 0x257C9D8)
local nindexed = 0
if tbl ~= nil and tbl ~= 0 then
  local nbuck   = u32(tbl + 0x28)
  local buckets = readQword(tbl + 0x20)
  if nbuck ~= nil and nbuck > 0 and nbuck < 1000000 and buckets ~= nil then
    for i = 0, nbuck - 1 do
      local node = readQword(buckets + i * 8)
      local guard = 0
      while node ~= nil and node ~= 0 and guard < 2000 do
        local def = readQword(node + 0x08)
        if def ~= nil and def ~= 0 then
          defToHash[def] = u32(node)
          nindexed = nindexed + 1
        end
        node = readQword(node + 0x28)
        guard = guard + 1
      end
    end
  end
end

nhits, ndetail = 0, 0
byFlag   = {}   -- [label] = { count, values = {[v]=n}, entities = {[ent]=vtable} }
marks    = {}

local function label(h)
  if h == nil then return "UNRESOLVED" end
  local n = KNOWN[h]
  if n then return string.format("%08X %s", h, n) end
  return string.format("%08X", h)
end

function mark(txt)
  table.insert(marks, { n = nhits, t = txt })
  print(string.format(">>> MARK at hit %d: %s", nhits, txt))
end

function clr()
  nhits, ndetail, byFlag, marks = 0, 0, {}, {}
  print("cleared.")
end

function sum()
  print("")
  print("================ SUMMARY ================")
  print(string.format("hits: %d", nhits))
  for _, m in ipairs(marks) do
    print(string.format("   mark at hit %-5d %s", m.n, m.t))
  end

  print("")
  print("-- flags checked, with values returned and the entities that asked --")
  local keys = {}
  for k in pairs(byFlag) do table.insert(keys, k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local f = byFlag[k]
    local vs = {}
    for v, n in pairs(f.values) do table.insert(vs, string.format("%d(x%d)", v, n)) end
    print(string.format("   %-50s  checked %dx   value %s", k, f.count, table.concat(vs, " ")))
    for ent, vt in pairs(f.entities) do
      print(string.format("        entity %X  vtable %s", ent, vt))
    end
  end
  print("=========================================")
end

function debugger_onBreakpoint()
  if RIP ~= BP then return 0 end

  nhits = nhits + 1

  local ent = RBX
  local vt  = ent and readQword(ent) or nil
  local def = ent and readQword(ent + 0x80) or nil
  local h   = def and defToHash[def] or nil
  local val = RAX and (RAX & 0xFFFFFFFF) or nil

  local k = label(h)
  local f = byFlag[k]
  if f == nil then
    f = { count = 0, values = {}, entities = {} }
    byFlag[k] = f
  end
  f.count = f.count + 1
  if val ~= nil then f.values[val] = (f.values[val] or 0) + 1 end
  if ent ~= nil then f.entities[ent] = rva(vt) end

  if ndetail < MAXDETAIL then
    ndetail = ndetail + 1
    print(string.format("#%-4d %-50s value=%s  entity=%X vtable=%s  def=%X",
      nhits, k, tostring(val), ent or 0, rva(vt), def or 0))
  end
  return 1
end

print(string.format("armed on %s+3A77E14 (absolute %X)", MODULE, BP))
print(string.format("indexed %d flag definitions from the table (expect ~2374)", nindexed))
if nindexed < 1000 then
  print("!! far fewer than expected -- the table pointer or node layout is off; results")
  print("   will show UNRESOLVED flags. Tell me before trusting anything below.")
end
print('Idle ~10s, then mark("idle baseline"), then DIE, then mark("after respawn"), then sum()')
