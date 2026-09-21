-- diag_apply.lua   (§62: why did the live apply work once and not again?)
--
-- §61: +3A75790(entity, value, 1) switched Switch Place with no death.
-- §62: same call, same entity type (321F), returned normally -- but the change
--      only took effect after a death.
--
-- This script does NOT guess. It:
--   1. prints the disassembly of +3A75790 (static) so we can see what it checks
--      before it acts (e.g. "only if value != last stored value");
--   2. probe(v, who):  snapshots the target entity's first 0x100 bytes, writes v
--      to the table, calls +3A75790(entity, v, 1), waits, snapshots again, and
--      prints every dword that CHANGED. If nothing changes, the call did nothing.
--      who = "live"    -> the 321F / 0x2000 entity (the §61 target)
--      who = "persist" -> the 121F entity that sits at a fixed address
--
-- v2: probe(v, who, r8) -- third arg is the r8b flag passed to +3A75790.
--   The disassembly shows: if data->vtable[0x20]() == 2 AND r8b == 0, the
--   function ALSO fires an event via +347E420(entity+30, 1). The respawn path
--   always passes r8b=1, so that event never fires there. probe(v,"live",0)
--   tests whether firing it is what makes a live change take effect.
--
-- v3: target(hash, name) switches the flag under test; check() restores
--   against the value it had when selected.
--
-- PROTOCOL  (die once after loading first, so the 321F entity exists)
--   a. Paste, Execute.  Send the disassembly with everything else at the end.
--   b. probe(0, "live")      -> try Switch Place. Works / doesn't?
--   c. probe(1, "live")      -> try again.
--   d. probe(0, "persist")   -> try again.
--   e. probe(1, "persist")   -> try again.
--   f. check()               -> confirms the table is back to 1
--   DON'T DIE until f shows 1. If anything crashes, the save is fine (last
--   autosave has 1) -- relaunch and tell me which step.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)
local ENT_VT = BASE + 0x1C7B168
local APPLY  = BASE + 0x3A75790
TARGET_HASH  = 0x67800619
TARGET_NAME  = "Unlocks_MoveEnemyBack (Switch Place)"
ORIGINAL     = nil   -- table value when the target was selected; check() restores to this
SNAP = 0x100

local function u32(a) local v = readInteger(a); if v and v < 0 then v = v + 0x100000000 end; return v end
local function rva(a) if a >= BASE and a < BASE + 0x10000000 then return string.format("+%X", a - BASE) end return string.format("%X", a) end

print("=== +3A75790, first 60 instructions ===")
local a = APPLY
for i = 1, 60 do
  print("   " .. rva(a) .. "   " .. disassemble(a))
  local sz = getInstructionSize(a)
  if sz == nil or sz == 0 then break end
  a = a + sz
end
print("")

local function lookupNode(h)
  local tbl = readQword(BASE + 0x257C9D8)
  local nb, bk = u32(tbl + 0x28), readQword(tbl + 0x20)
  local n = readQword(bk + (h % nb) * 8)
  local g = 0
  while n and n ~= 0 and g < 2000 do
    if u32(n) == h then return n end
    n = readQword(n + 0x28); g = g + 1
  end
end

local function vtPattern(v)
  local s = {}
  for i = 0, 7 do s[#s + 1] = string.format("%02X", (v >> (i * 8)) & 0xFF) end
  return table.concat(s, " ")
end

local function find(who)
  local node = lookupNode(TARGET_HASH)
  local n10 = node and readQword(node + 0x10)
  local out = {}
  local hits = AOBScan(vtPattern(ENT_VT), "+W", 1, "8")
  if hits then
    for i = 0, hits.Count - 1 do
      local e = tonumber(hits[i], 16)
      if readQword(e + 0x80) == n10 then
        local fl = u32(e + 0x18)
        local live = (fl & 0x2000) ~= 0
        if (who == "live" and live) or (who == "persist" and not live) then
          table.insert(out, { e = e, flags = fl })
        end
      end
    end
    hits.destroy()
  end
  return out, node
end

local function snap(e)
  local b = readBytes(e, SNAP, true)
  local d = {}
  for i = 0, SNAP / 4 - 1 do
    d[i] = (b[i*4+1] or 0) + (b[i*4+2] or 0) * 256 + (b[i*4+3] or 0) * 65536 + (b[i*4+4] or 0) * 16777216
  end
  return d
end

function probe(v, who, r8)
  who = who or "live"
  r8 = r8 or 1
  local c, node = find(who)
  if #c ~= 1 then
    print(string.format("!! %d '%s' candidates (need 1). Refusing. (Died once since loading?)", #c, who))
    for _, x in ipairs(c) do print(string.format("   %X flags=%X", x.e, x.flags)) end
    return
  end
  local e = c[1].e
  print(string.format("--- probe(%d, %s, r8=%d): entity %X flags=%X ---", v, who, r8, e, c[1].flags))
  local data = readQword(e + 0x28)
  if data then print(string.format("   data %X  data->vtable[0x20] = %s  (the 'mode' function; mode==2 && r8==0 fires +347E420)", data, rva(readQword(readQword(data) + 0x20)))) end
  local before = snap(e)
  local tb = u32(node + 0x18)
  writeInteger(node + 0x18, v)
  print(string.format("   table %08X: %d -> %d", TARGET_HASH, tb, u32(node + 0x18)))
  local ok, r = pcall(executeCodeEx, 0, 3000, APPLY, {type=0,value=e}, {type=0,value=v}, {type=0,value=r8})
  print("   call: " .. (ok and ("returned rax=" .. tostring(r)) or ("FAILED " .. tostring(r))))
  sleep(300)
  local after = snap(e)
  local nchg = 0
  for i = 0, SNAP / 4 - 1 do
    if before[i] ~= after[i] then
      nchg = nchg + 1
      print(string.format("   entity+%03X  %08X -> %08X", i * 4, before[i], after[i]))
    end
  end
  if nchg == 0 then print("   (no bytes changed in the first 0x100 of the entity)") end
  print("   now check in-game (" .. TARGET_NAME .. ") and note what you see")
end

-- v3: pick any flag. Records its CURRENT table value as ORIGINAL so check()
-- knows what "safe" means (1 for Switch Place, 0 for a never-owned upgrade).
function target(h, name)
  TARGET_HASH, TARGET_NAME = h, name or string.format("%08X", h)
  local node = lookupNode(h)
  if node == nil then print("!! hash not in table") return end
  ORIGINAL = u32(node + 0x18)
  local l = find("live")
  print(string.format("target = %08X %s   current table value = %d   live candidates = %d",
    h, TARGET_NAME, ORIGINAL, #l))
end

function check()
  local node = lookupNode(TARGET_HASH)
  local v = u32(node + 0x18)
  local want = ORIGINAL or 1
  print(string.format("table %08X %s = %d (original %d)  %s", TARGET_HASH, TARGET_NAME, v, want,
    v == want and "(OK, safe to die)" or string.format("(!! NOT original -- run probe(%d,'live',0) before dying)", want)))
end

ORIGINAL = u32(lookupNode(TARGET_HASH) + 0x18)
local l = find("live"); local p = find("persist")
print(string.format("live (0x2000) candidates: %d   persistent candidates: %d", #l, #p))
print('Run: probe(0,"live") ... probe(1,"live") ... probe(0,"persist") ... probe(1,"persist") ... check()')
