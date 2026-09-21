-- flag_hashmap.lua
--
-- Tests the hypothesis from reading +39E1F20 (§56): the live progression-flag
-- store is a hash map reached through the STATIC pointer at
--   MirrorsEdgeCatalyst.exe + 0x257C9D8
-- The game code at +39E2268..+39E22D9 looks a flag up like this:
--   tbl     = [module+257C9D8]
--   nbuck   = dword [tbl+28]
--   buckets = qword [tbl+20]
--   node    = buckets[hash % nbuck]
--   while node: if dword[node] == hash -> value = dword[node+18]
--               else node = qword[node+28]
--
-- READ-ONLY unless you set NEW_VALUE. Run it in-game, unpaused.
--
-- What would FALSIFY the hypothesis (check these in the output):
--   * table pointer null / bucket count absurd
--   * probe values disagree with what we know (XP_Used should be 17000,
--     the three abilities bought tonight should be 1, a never-bought
--     ability should be absent)
--   * TimeOfDay_CurrentTime does NOT change between the two samples
--     (the snapshot buffers never ticked; a live store should)

local TARGET_HASH = 0x67800619   -- Unlocks_MoveEnemyBack (Switch Place)
local NEW_VALUE   = nil          -- nil = read only. 0 = revoke, 1 = grant.

local BASE   = getAddress("MirrorsEdgeCatalyst.exe")
local GLOBAL = BASE + 0x257C9D8

local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

local tbl = readQword(GLOBAL)
print(string.format("global  [module+257C9D8] @ %X -> table %X", GLOBAL, tbl or 0))
if tbl == nil or tbl == 0 then print("table pointer is null -- hypothesis fails here.") return end

local nbuck   = u32(tbl + 0x28)
local buckets = readQword(tbl + 0x20)
print(string.format("bucket count = %s   bucket array = %X", tostring(nbuck), buckets or 0))
if nbuck == nil or nbuck == 0 or nbuck > 1000000 or buckets == nil then
  print("bucket count/array implausible -- hypothesis fails here.") return
end

-- raw header, for layout sanity
local hb = readBytes(tbl, 0x40, true)
if hb then
  for row = 0, 3 do
    local s = ""
    for c = 0, 15 do s = s .. string.format("%02X ", hb[row*16+c+1]) end
    print(string.format("  tbl+%02X  %s", row*16, s))
  end
end

local function lookup(h)
  local node = readQword(buckets + (h % nbuck) * 8)
  local guard = 0
  while node ~= nil and node ~= 0 and guard < 2000 do
    if u32(node) == h then return node end
    node = readQword(node + 0x28)
    guard = guard + 1
  end
  return nil
end

-- full enumeration: how many entries, and is every chain well-formed?
local total, maxchain = 0, 0
for i = 0, nbuck - 1 do
  local node = readQword(buckets + i * 8)
  local len = 0
  while node ~= nil and node ~= 0 and len < 2000 do
    total = total + 1; len = len + 1
    node = readQword(node + 0x28)
  end
  if len > maxchain then maxchain = len end
end
print(string.format("entries = %d   longest chain = %d", total, maxchain))

local PROBES = {
  { "Unlocks_MoveEnemyBack (bought tonight)",  0x67800619, "1" },
  { "Unlocks_DoubleWallrun (bought tonight)",  0xF139B4B3, "1" },
  { "Unlocks_FastClimb     (bought tonight)",  0x6F18BEF0, "1" },
  { "Unlocks_Shift         (long owned)",      0x2B48D119, "1" },
  { "Unlocks_ExtendedSlide (long owned)",      0x427FB289, "1" },
  { "Unlocks_Focus         (reset in s55)",    0x2C9CC1D5, "0 or absent" },
  { "Unlocks_FlowAttack_Special_PowerAttack",  0x17EEE7F5, "absent (never bought)" },
  { "XP_Used",                                 0xE5691AD5, "17000" },
  { "XP_Gained",                               0xFB042232, "1002674" },
}

print("")
print("probe                                        expect                 got")
for _, p in ipairs(PROBES) do
  local n = lookup(p[2])
  local got = n and string.format("%d   (node %X)", u32(n + 0x18), n) or "ABSENT"
  print(string.format("  %-42s %-22s %s", p[1], p[3], got))
end

-- first found node, dumped, to confirm the +0x18 value / +0x28 next layout
local n0 = lookup(0xE5691AD5)
if n0 then
  local b = readBytes(n0, 0x30, true)
  print("\nXP_Used node raw:")
  for row = 0, 2 do
    local s = ""
    for c = 0, 15 do s = s .. string.format("%02X ", b[row*16+c+1]) end
    print(string.format("  +%02X  %s", row*16, s))
  end
end

-- liveness: does the clock tick in THIS store?
local tn = lookup(0x55A782C6)   -- TimeOfDay_CurrentTime
if tn then
  local t1 = u32(tn + 0x18)
  sleep(3000)
  local t2 = u32(tn + 0x18)
  print(string.format("\nTimeOfDay_CurrentTime: %d -> %d  %s", t1, t2,
    t1 ~= t2 and "(TICKS -- live store)" or "(did not change in 3s)"))
else
  print("\nTimeOfDay_CurrentTime not in this table.")
end

if NEW_VALUE ~= nil then
  local t = lookup(TARGET_HASH)
  if t == nil then
    print(string.format("\nTARGET %08X absent -- cannot grant by value write.", TARGET_HASH))
  else
    local before = u32(t + 0x18)
    writeInteger(t + 0x18, NEW_VALUE)
    print(string.format("\nWROTE %08X: %d -> %d  (node %X)", TARGET_HASH, before, u32(t + 0x18), t))
  end
else
  print("\nREAD-ONLY. Set NEW_VALUE only after the probes all match.")
end
