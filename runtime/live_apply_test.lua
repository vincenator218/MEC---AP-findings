-- live_apply_test.lua   (§61: apply a flag change WITHOUT dying)
--
-- From the §61 disassembly:
--   +31661C0(entity, event): if [entity+18] bit 3 set -> return (inactive);
--                            else jump to vtable slot 15 = +3A77DC0
--   +3A77DC0(entity):        data = [entity+28]
--                            if byte [data+3A] != 0 -> return
--                            if [entity+80]==0: look up hash [data+34], cache it
--                            eax = flag value from the §56 table
--                            jmp +3A75790(entity, value, 1)    <-- APPLY
--
-- So the ability is switched by ONE call:  +3A75790(entity, value, 1)
-- No event object, no stale pointers. This script:
--   1. FINDS the live flag-check entity for a hash by scanning memory for
--      objects with vtable +1C7B168 whose [[+28]+34] == hash (no death needed;
--      this is how an AP client would find it)
--   2. revoke() -- writes 0 to the table AND calls +3A75790(entity, 0, 1)
--   3. grant()  -- writes 1 to the table AND calls +3A75790(entity, 1, 1)
--
-- The table write keeps the save and future respawns consistent; the call is
-- what should make it take effect immediately.
--
-- CALLING GAME CODE: executeCodeEx runs the call on a NEW thread inside the
-- game, not the game's own thread. For a single small call this is usually
-- fine, but it CAN crash the game. If it does: the save on disk is unaffected
-- (it still has Switch Place = 1 from the last autosave), just relaunch.
--
-- AUTOSAVE RULE (§59): never die, and don't reach a checkpoint, while the
-- flag is 0. Always finish with grant().
--
-- v2: every revoke()/grant() re-scans and only calls an entity that has the
-- right cached flag pointer AND bit 0x2000 set in [+18] (the bit that was set
-- only on the current respawn's entity in §61). If that doesn't pick exactly
-- one entity, it refuses and writes nothing.
--
-- USAGE (no breakpoints needed -- remove any that are still set)
--   1. Paste, Execute.  It scans and lists candidate entities. Read-only so far.
--   2. revoke()   then try Switch Place on an enemy.  DON'T DIE.
--   3. grant()    then try Switch Place again.
--   4. Report what happened after each step.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)
local ENT_VT = BASE + 0x1C7B168
local APPLY  = BASE + 0x3A75790

TARGET_HASH = 0x67800619   -- Unlocks_MoveEnemyBack (Switch Place)

local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

local function rva(a)
  if a == nil then return "nil" end
  if a >= BASE and a < BASE + 0x10000000 then return string.format("+%X", a - BASE) end
  return string.format("%X", a)
end

-- ------------------------------------------------ flag table lookup (§56)
local function lookupNode(h)
  local tbl = readQword(BASE + 0x257C9D8)
  local nb  = u32(tbl + 0x28)
  local bk  = readQword(tbl + 0x20)
  local node = readQword(bk + (h % nb) * 8)
  local g = 0
  while node ~= nil and node ~= 0 and g < 2000 do
    if u32(node) == h then return node end
    node = readQword(node + 0x28)
    g = g + 1
  end
  return nil
end

-- ------------------------------------------------ find the entity
local function vtPattern(v)
  local s = {}
  for i = 0, 7 do s[#s + 1] = string.format("%02X", (v >> (i * 8)) & 0xFF) end
  return table.concat(s, " ")
end

CANDIDATES = {}
local node = lookupNode(TARGET_HASH)
local node10 = node and readQword(node + 0x10) or nil

local hits = AOBScan(vtPattern(ENT_VT), "+W", 1, "8")
local scanned = 0
if hits ~= nil then
  scanned = hits.Count
  for i = 0, hits.Count - 1 do
    local e = tonumber(hits[i], 16)
    local data = readQword(e + 0x28)
    local h = data and u32(data + 0x34) or nil
    local cached = readQword(e + 0x80)
    if h == TARGET_HASH or (cached ~= nil and cached ~= 0 and cached == node10) then
      table.insert(CANDIDATES, {
        e = e, data = data, h = h, cached = cached,
        flags = u32(e + 0x18), skip = data and readBytes(data + 0x3A, 1, false) or nil,
      })
    end
  end
  hits.destroy()
end

print(string.format("scanned %d objects with vtable %s", scanned, rva(ENT_VT)))
print(string.format("table node for %08X: %X   (node+10 = %X)", TARGET_HASH, node or 0, node10 or 0))
print(string.format("%d candidate entit%s for %08X:", #CANDIDATES, #CANDIDATES == 1 and "y" or "ies", TARGET_HASH))
for i, c in ipairs(CANDIDATES) do
  local inactive = c.flags and ((c.flags >> 3) & 1) == 1
  print(string.format("  [%d] entity %X  hash@data+34=%s  cached[+80]=%X  flags[+18]=%X%s  skip[data+3A]=%s%s",
    i, c.e, c.h and string.format("%08X", c.h) or "nil", c.cached or 0, c.flags or 0,
    ((c.flags or 0) & 0x2000) ~= 0 and " (0x2000 = current respawn)" or "", tostring(c.skip),
    (EVT and EVT.entity == c.e) and "   <== the entity dump_event captured" or ""))
end

-- choose: exactly one candidate with bit 0x2000 in [+18]. (v1 used "bit 3
-- clear" here, which was wrong -- every entity has bit 3 set.) Observed so far:
-- the 0x2000 entity is replaced every respawn and is the one that worked in
-- §61; a second one with flags 121F sits at a fixed address across deaths.
-- revoke()/grant() re-run this same rule at call time, so this is a preview.
TARGET = nil
local sel = {}
for _, c in ipairs(CANDIDATES) do
  if c.flags and (c.flags & 0x2000) ~= 0 and c.cached == node10 then table.insert(sel, c) end
end
if #sel == 1 then TARGET = sel[1] end

if TARGET then
  print(string.format("\nwould target entity %X (flags %X). Run revoke() / grant().", TARGET.e, TARGET.flags))
else
  print(string.format("\n!! %d candidates with bit 0x2000 (need exactly 1). Send this output -- revoke/grant will refuse anyway.", #sel))
end

-- ------------------------------------------------ the test
-- v2 (after a crash on a repeated revoke): the target is RE-FOUND and
-- VALIDATED immediately before every call, instead of trusting the one picked
-- when the script was loaded. A respawn/checkpoint rebuilds the entity, and
-- calling +3A75790 on the old (freed) one crashes the game.
local function refind()
  node = lookupNode(TARGET_HASH)
  node10 = node and readQword(node + 0x10) or nil
  local live = {}
  local hits = AOBScan(vtPattern(ENT_VT), "+W", 1, "8")
  if hits ~= nil then
    for i = 0, hits.Count - 1 do
      local e = tonumber(hits[i], 16)
      local cached = readQword(e + 0x80)
      local fl = u32(e + 0x18)
      if cached ~= nil and cached ~= 0 and cached == node10 and fl ~= nil then
        table.insert(live, { e = e, flags = fl, cached = cached })
      end
    end
    hits.destroy()
  end
  return live
end

local function apply(v)
  local live = refind()
  local with2000 = {}
  for _, c in ipairs(live) do
    print(string.format("  candidate %X  flags=%X  %s", c.e, c.flags,
      ((c.flags & 0x2000) ~= 0) and "(0x2000 set)" or ""))
    if (c.flags & 0x2000) ~= 0 then table.insert(with2000, c) end
  end
  if #with2000 ~= 1 then
    print(string.format("!! %d candidates with bit 0x2000 set (need exactly 1). REFUSING to call.", #with2000))
    print("   Send this output. Nothing was written.")
    return
  end
  TARGET = with2000[1]
  if readQword(TARGET.e) ~= ENT_VT then print("!! vtable mismatch, refusing.") return end
  if node == nil then print("table node not found, refusing.") return end

  local before = u32(node + 0x18)
  writeInteger(node + 0x18, v)
  print(string.format("table: %08X  %d -> %d", TARGET_HASH, before, u32(node + 0x18)))

  print(string.format("calling +3A75790(entity=%X, value=%d, 1) ...", TARGET.e, v))
  local ok, ret = pcall(executeCodeEx, 0, 3000, APPLY,
    { type = 0, value = TARGET.e },
    { type = 0, value = v },
    { type = 0, value = 1 })
  if ok then
    print(string.format("  returned (rax=%s). Now try Switch Place on an enemy. DON'T DIE.", tostring(ret)))
  else
    print("  executeCodeEx failed: " .. tostring(ret))
  end
end

function revoke() apply(0) end
function grant()  apply(1) end
