-- exclusion_step2.lua -- STEP 2: find the movement exclusion volumes in memory
--
-- READ ONLY. Writes nothing, calls nothing.
--
-- How it works: step 1 showed that each class's type info holds a "default object"
-- at typeinfo+0x20, and that object's first qword is the vtable shared by every
-- instance of that class. So we read the vtable out of the default object, then
-- scan writable memory for pointers to it. Each hit is an instance base.
--
-- This is the same technique that found the flag-check entities in FINDINGS §56.
--
-- Run in free roam first, then (step 3) in the Back in the Game courtyard, and
-- compare the counts.
--
-- The scan can take 10-60 seconds. Send me the whole output.

local BASE = getAddress("MirrorsEdgeCatalyst.exe")

local function hx(v) return string.format("%X", v or 0) end
local function rq(a) local ok,v = pcall(readQword,a);  if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a);  if ok then return v end end

-- classes we want, with the field offsets from ME-AP\SDK\ (FINDINGS §82)
local CLASSES = {
  {
    name   = "PamMovementExclusionEntityData",
    ti     = 0x2878C00,
    -- derives PamFindableMovementVolumeEntityData
    fields = { HalfExtents = 0x80, Enabled = 0x90,
               ExcludeVault = 0xA0, ExcludeHeaveUp = 0xA1, ExcludeHang = 0xA2,
               ExcludeWallrun = 0xA3, ExcludeMagrope = 0xA4 },
    vec3   = { HalfExtents = true },
    bools  = { "Enabled","ExcludeVault","ExcludeHeaveUp","ExcludeHang",
               "ExcludeWallrun","ExcludeMagrope" },
  },
  {
    name   = "PamMovementExclusionVolume",
    ti     = 0x2878C60,
    -- derives PamFindableMovementVolumeData (Enabled at 0x70)
    fields = { Enabled = 0x70,
               ExcludeVault = 0x80, ExcludeHeaveUp = 0x81, ExcludeHang = 0x82,
               ExcludeWallrun = 0x83, ExcludeMagrope = 0x84 },
    vec3   = {},
    bools  = { "Enabled","ExcludeVault","ExcludeHeaveUp","ExcludeHang",
               "ExcludeWallrun","ExcludeMagrope" },
  },
}

local MAX_PRINT = 30

local function describe(cls, addr)
  local parts = {}
  for _, b in ipairs(cls.bools) do
    local v = rb(addr + cls.fields[b])
    parts[#parts+1] = string.format("%s=%s", b:gsub("^Exclude",""), tostring(v))
  end
  local s = table.concat(parts, " ")
  if cls.vec3.HalfExtents then
    local o = cls.fields.HalfExtents
    s = s .. string.format("  HalfExtents=(%.1f, %.1f, %.1f)",
            rf(addr+o) or 0, rf(addr+o+4) or 0, rf(addr+o+8) or 0)
  end
  return s
end

print("=== exclusion_step2 ===")
print("module base = " .. hx(BASE))
print("")

for _, cls in ipairs(CLASSES) do
  print("################ " .. cls.name)
  local ti = BASE + cls.ti
  local default_obj = rq(ti + 0x20)
  if not default_obj then
    print("  no default object at typeinfo+0x20 -- cannot derive a vtable. skipping.")
    goto continue
  end
  local vtable = rq(default_obj)
  if not vtable then
    print("  default object has no vtable pointer. skipping.")
    goto continue
  end
  print(string.format("  default object = %s   vtable = %s", hx(default_obj), hx(vtable)))
  print("  default values: " .. describe(cls, default_obj))

  -- build the little-endian byte pattern for the vtable pointer
  local pat = {}
  local v = vtable
  for _ = 1, 8 do pat[#pat+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  local pattern = table.concat(pat, " ")
  print("  scanning writable memory for: " .. pattern)

  local t0 = os.clock()
  local hits = AOBScan(pattern, "+W", 0, 8)   -- writable, aligned to 8
  local elapsed = os.clock() - t0

  if not hits then
    print(string.format("  0 instances found (%.1fs). This class is not present in memory right now.", elapsed))
  else
    local n = hits.getCount()
    print(string.format("  %d candidate instance(s) found in %.1fs", n, elapsed))
    local shown = 0
    local live = 0
    for i = 0, n - 1 do
      local addr = tonumber(hits.getString(i), 16)
      -- the default object itself will be one of the hits; label it
      local tag = (addr == default_obj) and "  <-- the class default, not a placed volume" or ""
      if addr ~= default_obj then live = live + 1 end
      if shown < MAX_PRINT then
        print(string.format("   [%2d] %s  %s%s", i, hx(addr), describe(cls, addr), tag))
        shown = shown + 1
      end
    end
    if n > MAX_PRINT then print(string.format("   ... and %d more not printed", n - MAX_PRINT)) end
    print(string.format("  => %d instance(s) besides the class default", live))
    hits.destroy()
  end
  print("")
  ::continue::
end

print("=== done. nothing was written. ===")
print("Tell me: which save/area you were in, and the counts for each class.")
