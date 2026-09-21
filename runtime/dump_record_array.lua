-- dump_record_array.lua
--
-- Read-only. Decodes the (u32 hash, u32 value) record arrays found by
-- identify_stat_objects.lua's Test A, by walking outward from a known record
-- until the data stops looking like records.
--
-- What this answers:
--   1. Do the four LIVE arrays contain ONLY owned flags (so a grant = insert),
--      or all flags with a 0/1 value (so a grant = flip the value)?
--   2. Where does each array start and end, and is there a count header?
--   3. Are all four live arrays identical copies, or do they differ?
--
-- Nothing is written. Send the whole output back; hashes get resolved to
-- names offline against the same djb2a dictionary decode_save.py uses.
--
-- NOTE: the anchor addresses below are from THIS session. After a restart
-- they will be wrong -- re-run identify_stat_objects.lua to get fresh ones.

local ANCHORS = {
  { label = "LIVE-1",  addr = 0x2BBCE0AC },
  { label = "LIVE-2",  addr = 0x2BC1E36C },
  { label = "LIVE-3",  addr = 0x2BC54A7C },
  { label = "LIVE-4",  addr = 0x2C6045C8 },
  { label = "STALE-X", addr = 0x2BBC6E6C },  -- layout X, for comparison
  { label = "STALE-Y", addr = 0x2BBC857C },  -- layout Y, for comparison
}

local MAXOUT = 1200   -- hard cap on records walked in each direction

local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

-- A record looks plausible if the hash is a nonzero 32-bit value that isn't a
-- small integer or an obvious pointer, and the value is small. Progression
-- values in this game are 0/1 booleans, small counters, or XP totals.
local function plausible(a)
  local h = u32(a)
  local v = u32(a + 4)
  if h == nil or v == nil then return false end
  if h == 0 then return false end
  if h < 0x10000 then return false end          -- too small to be a djb2a hash
  if v > 0x00FFFFFF then return false end       -- values are never this large
  return true
end

for _, anc in ipairs(ANCHORS) do
  print(string.format("\n================ %s  anchor %X ================", anc.label, anc.addr))

  if not plausible(anc.addr) then
    print("  anchor no longer looks like a record -- memory moved? re-run Test A.")
    goto continue
  end

  -- walk backwards to the first record
  local first = anc.addr
  local miss = 0
  for i = 1, MAXOUT do
    local a = anc.addr - i * 8
    if plausible(a) then
      first = a
      miss = 0
    else
      miss = miss + 1
      if miss >= 4 then break end   -- 4 consecutive duds = past the start
    end
  end

  -- walk forwards to the last record
  local last = anc.addr
  miss = 0
  for i = 1, MAXOUT do
    local a = anc.addr + i * 8
    if plausible(a) then
      last = a
      miss = 0
    else
      miss = miss + 1
      if miss >= 4 then break end
    end
  end

  local n = (last - first) / 8 + 1
  print(string.format("  array spans %X .. %X  (%d records, anchor is #%d)",
    first, last, n, (anc.addr - first) / 8))

  -- dump the 32 bytes before the array -- a count/length header often sits here
  print("  header bytes immediately before the array:")
  local hb = readBytes(first - 32, 32, true)
  if hb ~= nil then
    for row = 0, 1 do
      local line = ""
      for col = 0, 15 do line = line .. string.format("%02X ", hb[row * 16 + col + 1]) end
      print(string.format("    -%02X  %s", 32 - row * 16, line))
    end
    print(string.format("    as dwords: -20=%08X -1C=%08X -18=%08X -14=%08X -10=%08X -0C=%08X -08=%08X -04=%08X",
      u32(first-32) or 0, u32(first-28) or 0, u32(first-24) or 0, u32(first-20) or 0,
      u32(first-16) or 0, u32(first-12) or 0, u32(first-8) or 0, u32(first-4) or 0))
  end

  -- dump every record, 4 per line
  print("  records (hash=value):")
  local line, cnt = "    ", 0
  for a = first, last, 8 do
    line = line .. string.format("%08X=%-8d ", u32(a), u32(a + 4))
    cnt = cnt + 1
    if cnt % 4 == 0 then
      print(line)
      line = "    "
    end
  end
  if line ~= "    " then print(line) end

  ::continue::
end

print("\nDone -- send the entire output back.")
