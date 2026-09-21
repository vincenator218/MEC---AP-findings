-- progression_poke.lua  (v2)
--
-- v1 BUG, FIXED HERE: v1 guessed the live array as "the one with the highest
-- TimeOfDay value". That is wrong -- the three ProgressionManagerData sections
-- are independent profiles with independent clocks, so a larger number does not
-- mean more recent. v1 therefore labelled the inert 228-record copies LIVE and
-- would have written into the wrong arrays.
--
-- v2 MEASURES liveness instead of inferring it: it samples TimeOfDay_CurrentTime
-- in every array, waits, and samples again. Only the array the game is actually
-- updating changes. It also cross-checks against the fingerprint verified against
-- the save file on disk (section _2411670393: 305 records, XP_Gained 1002674).
--
-- No write happens unless you name the exact headers to write to. There is no
-- automatic "it's probably this one".
--
-- THE ARRAYS: each ProgressionManagerData* save section is loaded verbatim as
--   [0xAFAFAFAF | count] followed by `count` records of (u32 nameHash, u32 value)
-- and the game keeps three identical copies of each. Buying an ability writes 1
-- over the existing 0 in the live copy, in place -- that is what this reproduces.
--
-- USAGE
--   1. Be IN-GAME and unpaused (a menu freezes the clock and the liveness test
--      needs it ticking). Execute with WRITE_TO = nil -> report only.
--   2. Copy the header(s) it marks LIVE into WRITE_TO, set NEW_VALUE, Execute.
--
-- SAFETY: a live write can reach disk, because a running game rewrites the save
-- from its own memory (§15a). Back up PROF_SAVE before the first write.

--==========================================================================
-- CONFIGURE
--==========================================================================
local TARGET_HASH = 0x67800619   -- Unlocks_MoveEnemyBack ("Switch Place", Combat)
local NEW_VALUE   = nil          -- nil = read only. 0 = revoke. 1 = grant.
local WRITE_TO    = nil          -- e.g. { 0x2BBCDD9C, 0x2BC1E05C, 0x2BC5476C }
local SETTLE_MS   = 3000         -- how long to wait between clock samples

-- reference hashes
local H_SHIFT     = 0x2B48D119   -- present in every progression array
local H_XPUSED    = 0xE5691AD5
local H_XPGAINED  = 0xFB042232
local H_TIMEOFDAY = 0x55A782C6
local HEADER      = 0xAFAFAFAF

-- fingerprint of the section proven live by diffing against PROF_SAVE on disk
local KNOWN_LIVE_COUNT     = 305
local KNOWN_LIVE_XPGAINED  = 1002674

--==========================================================================
local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

local function findHeader(recAddr)
  for i = 0, 1200 do
    if u32(recAddr - i * 8) == HEADER then return recAddr - i * 8 end
  end
  return nil
end

local function indexArray(hdr)
  local count = u32(hdr + 4)
  if count == nil or count < 10 or count > 20000 then return nil end
  local idx = {}
  for i = 1, count do
    local h = u32(hdr + i * 8)
    if h == nil then break end
    idx[h] = hdr + i * 8
  end
  return { hdr = hdr, count = count, idx = idx }
end

print("=== scanning for progression record arrays ===")
local pat = string.format("%02X %02X %02X %02X",
  H_SHIFT & 0xFF, (H_SHIFT >> 8) & 0xFF, (H_SHIFT >> 16) & 0xFF, (H_SHIFT >> 24) & 0xFF)
local hits = AOBScan(pat, "+W", 1, "4")
if hits == nil then print("no hits -- game running with a save loaded?") return end

local arrays, seen = {}, {}
for i = 0, hits.Count - 1 do
  local hdr = findHeader(tonumber(hits[i], 16))
  if hdr and not seen[hdr] then
    seen[hdr] = true
    local a = indexArray(hdr)
    if a and a.idx[H_XPUSED] and a.idx[H_TIMEOFDAY] then
      a.xpUsed   = u32(a.idx[H_XPUSED] + 4)
      a.xpGained = a.idx[H_XPGAINED] and u32(a.idx[H_XPGAINED] + 4) or -1
      a.clock1   = u32(a.idx[H_TIMEOFDAY] + 4)
      table.insert(arrays, a)
    end
  end
end
hits.destroy()
if #arrays == 0 then print("no valid arrays found.") return end

--==========================================================================
-- LIVENESS: measured, not guessed
--==========================================================================
print(string.format("sampling %d array(s), waiting %dms, sampling again...", #arrays, SETTLE_MS))
print("(you must be IN-GAME and unpaused -- a menu freezes the clock)")
sleep(SETTLE_MS)

local anyTicked = false
for _, a in ipairs(arrays) do
  a.clock2 = u32(a.idx[H_TIMEOFDAY] + 4)
  a.ticked = (a.clock2 ~= a.clock1)
  if a.ticked then anyTicked = true end
  a.fingerprint = (a.count == KNOWN_LIVE_COUNT and a.xpGained == KNOWN_LIVE_XPGAINED)
end

print("")
print(string.format("  %-10s %-6s %-10s %-8s %-15s %-8s %-6s %s",
  "header", "count", "XP_Gained", "XP_Used", "clock t1->t2", "TICKED", "match", "target"))
for _, a in ipairs(arrays) do
  local ta = a.idx[TARGET_HASH]
  print(string.format("  %-10X %-6d %-10d %-8d %-15s %-8s %-6s %s",
    a.hdr, a.count, a.xpGained, a.xpUsed,
    string.format("%d->%d", a.clock1, a.clock2),
    a.ticked and "YES" or "no",
    a.fingerprint and "YES" or "no",
    ta and string.format("%08X = %d  @ %X", TARGET_HASH, u32(ta + 4), ta + 4)
        or string.format("%08X ABSENT", TARGET_HASH)))
end

print("")
if not anyTicked then
  print("!! NO array's clock changed. Either you were paused/in a menu, or the")
  print("   wait was too short. The 'match' column still identifies the section")
  print("   verified against PROF_SAVE on disk -- trust that, or re-run in-game.")
else
  print("Arrays marked TICKED=YES are the ones the game is actively updating.")
  print("They should also be the ones with match=YES. If TICKED and match")
  print("DISAGREE, stop and report it -- do not write.")
end

--==========================================================================
if NEW_VALUE == nil or WRITE_TO == nil then
  print("\nREAD-ONLY. To write: copy the chosen header(s) into WRITE_TO,")
  print("set NEW_VALUE, and Execute again. No array is selected automatically.")
  return
end

local chosen = {}
for _, want in ipairs(WRITE_TO) do
  local found = nil
  for _, a in ipairs(arrays) do if a.hdr == want then found = a end end
  if found == nil then
    print(string.format("\nABORT: header %X is not among the arrays found. Re-run read-only.", want))
    return
  end
  table.insert(chosen, found)
end

print(string.format("\n=== WRITING %d to %08X in %d array(s) ===", NEW_VALUE, TARGET_HASH, #chosen))
for _, a in ipairs(chosen) do
  local ta = a.idx[TARGET_HASH]
  if ta == nil then
    print(string.format("  %X: target ABSENT -- cannot grant by value write, skipped", a.hdr))
  else
    local before = u32(ta + 4)
    writeInteger(ta + 4, NEW_VALUE)
    local after = u32(ta + 4)
    print(string.format("  %X: %X = %d -> %d  %s", a.hdr, ta + 4, before, after,
      after == NEW_VALUE and "OK" or "** DID NOT STICK **"))
  end
end
print("\nNow check the ability in-game. To undo, set NEW_VALUE back and Execute.")
