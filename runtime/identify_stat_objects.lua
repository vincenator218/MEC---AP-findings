-- identify_stat_objects.lua
--
-- Two independent tests, both read-only, neither needs a purchase.
--
-- TEST A -- find the save-file record array in live memory.
--   The save stores progression as a packed array of (u32 hash, u32 value)
--   pairs (patch_save.py reads them at blob+148+i*8). The game has to build
--   that array from something, so the same shape very likely exists in RAM.
--   We scan for the hash of a flag whose CURRENT value we know for certain,
--   then look at the 4 bytes after each hit. A hit followed by exactly the
--   right value -- and neighbours that are also known flag hashes -- is the
--   authoritative live ownership store, and writing to it IS the grant.
--   This would make the entire tree question moot.
--
-- TEST B -- name the 18 objects that +39E1700 iterates.
--   Dump each one's header so we can resolve what they actually are. If any
--   field is a name hash we can reverse it offline against the same djb2a
--   dictionary decode_save.py uses; if any is a char* we read it directly.
--
-- Run: Ctrl+Alt+L, paste, Execute Script. Copy the whole output back.
-- No breakpoint needed -- disable the +39E1700 one first so the game runs free.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE = getAddress(MODULE)

local function rva(a)
  if a == nil then return "nil" end
  if a >= BASE and a < BASE + 0x10000000 then return string.format("+%X", a - BASE) end
  return string.format("%X", a)
end

local function u32(a) local v = readInteger(a); if v ~= nil and v < 0 then v = v + 0x100000000 end; return v end

--==========================================================================
-- TEST A: hunt the (hash, value) record array
--==========================================================================
-- Flags whose exact current value we know, from the save + this session's
-- purchases. The two purchased Movement ones should now read 1 in memory.
local PROBES = {
  { name = "Unlocks_DoubleWallrun", hash = 0xF139B4B3, expect = 1 },  -- bought this session
  { name = "Unlocks_FastClimb",     hash = 0x6F18BEF0, expect = 1 },  -- bought this session
  { name = "Unlocks_Shift",         hash = 0x2B48D119, expect = 1 },  -- long-owned
  { name = "Unlocks_Focus",         hash = 0x2C9CC1D5, expect = 0 },  -- reset in §55, NOT bought
}

print("=========== TEST A: (hash,value) record array ===========")
for _, p in ipairs(PROBES) do
  local pat = string.format("%02X %02X %02X %02X",
    p.hash & 0xFF, (p.hash >> 8) & 0xFF, (p.hash >> 16) & 0xFF, (p.hash >> 24) & 0xFF)
  print(string.format("\n-- %s  (hash %08X, expect value %d)  pattern '%s'",
    p.name, p.hash, p.expect, pat))
  local hits = AOBScan(pat, "+W", 1, "4")   -- writable regions, 4-byte aligned
  if hits == nil then
    print("   no hits")
  else
    print(string.format("   %d hit(s)%s", hits.Count, hits.Count > 60 and " (showing first 60)" or ""))
    for i = 0, math.min(hits.Count, 60) - 1 do
      local a = tonumber(hits[i], 16)
      -- the candidate value sits immediately after the hash in a packed pair
      local val  = u32(a + 4)
      -- neighbouring records, if this really is a stride-8 array
      local pH   = u32(a - 8)
      local nH   = u32(a + 8)
      local flag = (val == p.expect) and "  <== VALUE MATCHES" or ""
      print(string.format("   %X  val=%-10s prevHash=%08X nextHash=%08X%s",
        a, tostring(val), pH or 0, nH or 0, flag))
    end
    hits.destroy()
  end
end

--==========================================================================
-- TEST B: identify the 18 objects passed as RDX to +39E1700
--==========================================================================
local OBJS = {
  0x2A1D87F8, 0x2A1D8848, 0x2A1D8AA8, 0x2A1D8D18, 0x2A1D8F28, 0x2A1D9078,
  0x2A1D9258, 0x2A1D9358, 0x2A1D97C0, 0x2A1D9DA8, 0x2A1D9FC8, 0x2A1DA0E8,
  0x2A1DA2D0, 0x2A1DA458, 0x2A1DA508, 0x2A1DA8B8, 0x2A1DA988, 0x2A1DB700,
}

-- does this address look like a readable ASCII string?
local function tryString(a)
  if a == nil or a < 0x10000 then return nil end
  local b = readBytes(a, 40, true)
  if b == nil then return nil end
  local s = ""
  for i = 1, #b do
    local c = b[i]
    if c == 0 then break end
    if c < 32 or c > 126 then return nil end
    s = s .. string.char(c)
  end
  if #s < 3 then return nil end
  return s
end

print("\n\n=========== TEST B: the 18 objects +39E1700 iterates ===========")
for _, o in ipairs(OBJS) do
  print(string.format("\n---- object %X ----", o))

  -- raw header
  local b = readBytes(o, 0x60, true)
  if b == nil then
    print("   UNREADABLE")
  else
    for row = 0, 5 do
      local line = ""
      for col = 0, 15 do
        line = line .. string.format("%02X ", b[row * 16 + col + 1])
      end
      print(string.format("   +%02X  %s", row * 16, line))
    end

    -- interpret every qword slot: pointer? string? and every dword as a hash candidate
    for off = 0, 0x58, 8 do
      local q = readQword(o + off)
      if q ~= nil and q ~= 0 then
        local s = tryString(q)
        local note = ""
        if s ~= nil then
          note = string.format("  -> STRING \"%s\"", s)
        elseif q >= BASE and q < BASE + 0x10000000 then
          note = string.format("  -> module %s", rva(q))
        end
        if note ~= "" then
          print(string.format("   qword +%02X = %X%s", off, q, note))
        end
      end
    end

    -- dword candidates for a name hash (printed so they can be reversed offline)
    local dwords = {}
    for off = 0, 0x5C, 4 do
      local v = u32(o + off)
      if v ~= nil and v > 0x1000 and v < 0xFFFFFFF0 then
        table.insert(dwords, string.format("+%02X=%08X", off, v))
      end
    end
    print("   hash candidates: " .. table.concat(dwords, " "))
  end
end

print("\nDone -- copy everything above and send it back.")
