-- persist_apply_test.lua   (§71: can a flag with NO live (0x2000) entity be applied live?)
--
-- §71: Unlocks_Focus -- a table write alone did nothing live, but the change
-- applied on the next death. Focus has no 0x2000 entity, only persistent
-- (121F) ones. This script calls +3A75790(entity, v, 0) on those persistent
-- entities -- the same call that works on the 0x2000 ones (§64-§69).
--
-- USAGE
--   1. Paste, Execute. It prints the flag's current value and every entity
--      for it (index, address, data pointer).
--   2. status()        -- re-print the value and entities
--   3. apply(i, v)     -- write v to the table AND call +3A75790 on entity #i
--      applyall(v)     -- same, on every listed entity
--      Test in-game after each call.
--   4. restore()       -- puts the table AND every entity back to ORIGINAL
--   Make sure restore() has printed OK before you die or reach a checkpoint.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)
local ENT_VT = BASE + 0x1C7B168
local APPLY  = BASE + 0x3A75790

TARGET_HASH = 0x2C9CC1D5      -- Unlocks_Focus
TARGET_NAME = "Unlocks_Focus"

local function u32(a) local v = readInteger(a); if v and v < 0 then v = v + 0x100000000 end; return v end

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

local function entities()
  local node = lookupNode(TARGET_HASH)
  local n10 = node and readQword(node + 0x10)
  local out = {}
  local pat = {}
  for i = 0, 7 do pat[#pat + 1] = string.format("%02X", (ENT_VT >> (i * 8)) & 0xFF) end
  local hits = AOBScan(table.concat(pat, " "), "+W", 1, "8")
  if hits then
    for i = 0, hits.Count - 1 do
      local e = tonumber(hits[i], 16)
      if n10 and readQword(e + 0x80) == n10 then
        out[#out + 1] = { e = e, fl = u32(e + 0x18) or 0, data = readQword(e + 0x28) or 0 }
      end
    end
    hits.destroy()
  end
  table.sort(out, function(a, b) return a.e < b.e end)
  return out, node
end

function status()
  local list, node = entities()
  if not node then print("!! hash not in table") return end
  print(string.format("%08X %s  table = %d  (original %s)", TARGET_HASH, TARGET_NAME,
    u32(node + 0x18), tostring(ORIGINAL)))
  for i, x in ipairs(list) do
    print(string.format("  [%d] entity %X  flags %04X  %s  entity+78=%d  data %X", i, x.e, x.fl & 0xFFFF,
      (x.fl & 0x2000) ~= 0 and "LIVE   " or "persist", u32(x.e + 0x78), x.data))
  end
  return list, node
end

local function call(e, v)
  local ok, r = pcall(executeCodeEx, 0, 3000, APPLY, {type=0,value=e}, {type=0,value=v}, {type=0,value=0})
  print(string.format("    +3A75790(%X, %d, 0): %s", e, v, ok and "returned" or ("FAILED " .. tostring(r))))
end

function apply(i, v)
  local list, node = entities()
  local x = list[i]
  if not x then print("!! no entity #" .. tostring(i) .. " -- run status()") return end
  if readQword(x.e) ~= ENT_VT then print("!! vtable mismatch, refusing") return end
  writeInteger(node + 0x18, v)
  print(string.format("table %08X -> %d", TARGET_HASH, v))
  call(x.e, v)
  print(string.format("  entity+78 now %d. Test in-game.", u32(x.e + 0x78)))
end

function applyall(v)
  local list, node = entities()
  writeInteger(node + 0x18, v)
  print(string.format("table %08X -> %d", TARGET_HASH, v))
  for _, x in ipairs(list) do
    if readQword(x.e) == ENT_VT then call(x.e, v) end
  end
  print("Test in-game.")
end

function restore()
  local list, node = entities()
  writeInteger(node + 0x18, ORIGINAL)
  for _, x in ipairs(list) do
    if readQword(x.e) == ENT_VT and u32(x.e + 0x78) ~= ORIGINAL then call(x.e, ORIGINAL) end
  end
  local ok = u32(node + 0x18) == ORIGINAL
  for _, x in ipairs(list) do if u32(x.e + 0x78) ~= ORIGINAL then ok = false end end
  print(ok and string.format("restored to %d -- OK, safe to die", ORIGINAL) or "!! NOT fully restored -- send this output")
end

local _, node0 = entities()
ORIGINAL = node0 and u32(node0 + 0x18)
status()
print("apply(i, v) / applyall(v) / status() / restore()")
