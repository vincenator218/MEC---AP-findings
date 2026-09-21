-- grant_test.lua   (§56 follow-up: does a 0 -> 1 write GRANT an ability?)
--
-- The revoke direction is proven (§56): writing 0 into the live flag hashmap
-- at [MirrorsEdgeCatalyst.exe+0x257C9D8] removes an ability at the next
-- respawn, and writing 1 back restores it. Both directions reproduced three
-- times. What is NOT yet proven is granting something that was NEVER owned --
-- a "revoke then restore" only shows the game can re-apply a flag it already
-- had this session.
--
-- TARGETS: the Combat stamina column ("+1 STAMINA"), which is what the menu
-- shows as Graphene Weave (purchasable) and Carbon Weave (LOCKED behind
-- mission SANCTUARY). Flag names Unlocks_IncreasedHealth0..4. Hash function
-- verified: djb2a("Unlocks_MoveEnemyBack") == 0x67800619, the flag proven in §56.
--
-- Granting a MISSION-LOCKED one is the strong version of the test: the menu
-- will not sell it at any price, so if it takes effect, the flag write bypasses
-- the mission gate entirely -- exactly what an Archipelago item needs to do.
--
-- MODE:
--   "read"     print current values, change nothing. START HERE.
--   "grant"    set every listed flag that is 0 to 1 (originals saved in _ORIG)
--   "restore"  put every listed flag back to the value read at "grant" time
--
-- PROTOCOL
--   1. MODE="read", Execute. Note the stamina segments on your health bar.
--   2. MODE="grant", Execute.
--   3. Die / restart from checkpoint. Do NOT quit to the main menu.
--   4. Count the stamina segments again, and take a few hits to feel it.
--      IGNORE THE PROGRESSION MENU -- §56 proved the menu reads a stale copy
--      and lies about what you actually have.
--   5. MODE="restore", Execute, then die once more so the game re-applies it.
--   6. MODE="read", Execute, and confirm every value matches step 1.
--
-- SAFETY: the game saves from this table, so never leave a session with values
-- you did not intend. Backup: PROF_SAVE.before_livepoke.

local MODE = "read"     -- "read" | "grant" | "restore"

local TARGETS = {
  { 0x848D8855, "Unlocks_IncreasedHealth0" },
  { 0x848D8854, "Unlocks_IncreasedHealth1" },
  { 0x848D8857, "Unlocks_IncreasedHealth2" },
  { 0x848D8856, "Unlocks_IncreasedHealth3" },
  { 0x848D8851, "Unlocks_IncreasedHealth4" },
}

-- a control, not written: proven in §56, so if this ever reads something
-- unexpected the table pointer is stale and nothing below should be trusted
local CONTROL = { 0x67800619, "Unlocks_MoveEnemyBack", 1 }

_ORIG = _ORIG or {}     -- global on purpose: survives between Execute presses

local BASE = getAddress("MirrorsEdgeCatalyst.exe")

local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

local tbl = readQword(BASE + 0x257C9D8)
if tbl == nil or tbl == 0 then print("table pointer null -- is a save loaded?") return end
local nbuck   = u32(tbl + 0x28)
local buckets = readQword(tbl + 0x20)
if nbuck == nil or nbuck == 0 or nbuck > 1000000 or buckets == nil then
  print("table header implausible -- aborting.") return
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

print(string.format("table %X  buckets %X  nbuck %d   MODE=%s", tbl, buckets, nbuck, MODE))

-- control check first: if this is wrong, stop before touching anything
local cn = lookup(CONTROL[1])
if cn == nil or u32(cn + 0x18) ~= CONTROL[3] then
  print(string.format("CONTROL FAILED: %s expected %d, got %s -- NOT writing anything.",
    CONTROL[2], CONTROL[3], cn and tostring(u32(cn + 0x18)) or "ABSENT"))
  print("Restore Switch Place to 1 first, then re-run.")
  return
end
print(string.format("control ok: %s = %d", CONTROL[2], CONTROL[3]))
print("")

for _, t in ipairs(TARGETS) do
  local h, name = t[1], t[2]
  local n = lookup(h)
  if n == nil then
    print(string.format("  %-28s %08X  ABSENT from table", name, h))
  else
    local v = u32(n + 0x18)
    if MODE == "read" then
      print(string.format("  %-28s %08X  = %d   (node %X)", name, h, v, n))

    elseif MODE == "grant" then
      if _ORIG[h] == nil then _ORIG[h] = v end
      if v == 0 then
        writeInteger(n + 0x18, 1)
        print(string.format("  %-28s %08X  GRANTED 0 -> %d   (was %d)", name, h, u32(n + 0x18), _ORIG[h]))
      else
        print(string.format("  %-28s %08X  already %d, left alone", name, h, v))
      end

    elseif MODE == "restore" then
      if _ORIG[h] == nil then
        print(string.format("  %-28s %08X  NO ORIGINAL RECORDED -- left at %d", name, h, v))
      else
        writeInteger(n + 0x18, _ORIG[h])
        print(string.format("  %-28s %08X  restored %d -> %d", name, h, v, u32(n + 0x18)))
      end
    end
  end
end

if MODE == "grant" then
  print("\nNow DIE or restart from checkpoint, then count your stamina segments.")
  print("Do not trust the Progression menu -- it reads a stale copy (§56).")
elseif MODE == "restore" then
  print("\nRestored. Die once more so the game re-applies the old set, then MODE='read' to verify.")
  print("Originals recorded this CE session:")
  for h, v in pairs(_ORIG) do print(string.format("  %08X = %d", h, v)) end
end
