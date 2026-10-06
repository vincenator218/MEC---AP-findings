-- exclusion_step5.lua -- STEP 5: which EntityData objects actually have a live entity?
--
-- Step 4 result: growing ONE volume to 50000 with ExcludeHeaveUp=1 did nothing,
-- while growing all 62 in step 3 blocked the mantle immediately. So reach is not
-- the issue -- the volume we picked has no spawned PamClientMovementExclusionEntity
-- attached to it. Its EntityData sits in memory unused (level data for an area that
-- is streamed out, or a template).
--
-- A spawned entity has to point at its EntityData. So: for each of the 62
-- EntityData addresses, scan for pointers to it. Anything with a referrer is live.
--
-- xrefs() takes roughly 2 seconds per volume -- about two minutes for 62. It prints
-- progress. Read only.
--
-- Then:
--   xsolo(i, size)   restore everything, grow ONLY volume i, ExcludeHeaveUp=1
--   xsololive(size)  restore everything, grow only the volumes that have referrers
--   xrestore()       put everything back

local BASE = getAddress("MirrorsEdgeCatalyst.exe")
local MODULE_SPAN = 0x4000000
local TI_ENTITYDATA = 0x2878C00
local OFF = { HalfExtents = 0x80, Enabled = 0x90,
              Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2, Wallrun = 0xA3, Magrope = 0xA4 }
local ORDER = { "Vault", "HeaveUp", "Hang", "Wallrun", "Magrope" }

local vols = {}
local function hx(v) return string.format("%X", v or 0) end
local function rq(a) local ok,v = pcall(readQword,a); if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a); if ok then return v end end

local function dump(v)
  local a, b = v.addr, {}
  for _, k in ipairs(ORDER) do b[#b+1] = k:sub(1,2) .. "=" .. tostring(rb(a+OFF[k])) end
  return string.format("%s En=%s %s ext=(%.0f,%.0f,%.0f)%s",
    hx(a), tostring(rb(a+OFF.Enabled)), table.concat(b," "),
    rf(a+OFF.HalfExtents) or 0, rf(a+OFF.HalfExtents+4) or 0, rf(a+OFF.HalfExtents+8) or 0,
    v.refs and string.format("  refs=%d", v.refs) or "")
end

local function ptr_pattern(addr)
  local p, v = {}, addr
  for _ = 1, 8 do p[#p+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  return table.concat(p, " ")
end

function xlist()
  vols = {}
  local ti = BASE + TI_ENTITYDATA
  local d = rq(ti + 0x20)
  local vt = d and rq(d)
  if not vt then print("no vtable -- game loaded?"); return end
  local hits = AOBScan(ptr_pattern(vt), "+W", 0, 8)
  if not hits then print("no instances"); return end
  for i = 0, hits.getCount() - 1 do
    local a = tonumber(hits.getString(i), 16)
    if a ~= d and not (a >= BASE and a <= BASE + MODULE_SPAN) then
      local e1 = rf(a + OFF.HalfExtents)
      if e1 and e1 >= 0 and e1 < 1e6 then
        local o = { ext = { e1, rf(a+OFF.HalfExtents+4), rf(a+OFF.HalfExtents+8) }, bools = {} }
        o.bools.Enabled = rb(a+OFF.Enabled)
        for _, k in ipairs(ORDER) do o.bools[k] = rb(a+OFF[k]) end
        vols[#vols+1] = { addr = a, orig = o }
      end
    end
  end
  hits.destroy()
  print(string.format("xlist: %d volume(s) recorded", #vols))
  return #vols
end

-- who points at each EntityData? anything that does is (probably) a spawned entity
function xrefs()
  if #vols == 0 then print("run xlist() first"); return end
  print(string.format("xrefs: scanning for referrers to %d EntityData objects.", #vols))
  print("  ~2s each, so this takes a couple of minutes. Progress every 10.")
  local live = 0
  for i, v in ipairs(vols) do
    local hits = AOBScan(ptr_pattern(v.addr), "+W", 0, 8)
    v.refs, v.ref1 = 0, nil
    if hits then
      local n = hits.getCount()
      for j = 0, n - 1 do
        local r = tonumber(hits.getString(j), 16)
        -- ignore the pointer inside the type table and self-references
        if r ~= v.addr and not (r >= BASE and r <= BASE + MODULE_SPAN) then
          v.refs = v.refs + 1
          if not v.ref1 then v.ref1 = r end
        end
      end
      hits.destroy()
    end
    if v.refs > 0 then live = live + 1 end
    if i % 10 == 0 then print(string.format("  ...%d/%d", i, #vols)) end
  end
  print("")
  print("volumes WITH referrers (candidate live volumes):")
  for i, v in ipairs(vols) do
    if v.refs > 0 then
      print(string.format("  [%2d] %s  first referrer=%s", i, dump(v), hx(v.ref1)))
    end
  end
  print("")
  print("volumes with NO referrer (probably unspawned level data):")
  local none = {}
  for i, v in ipairs(vols) do if v.refs == 0 then none[#none+1] = i end end
  print("  " .. table.concat(none, ", "))
  print(string.format("=> %d of %d have at least one referrer", live, #vols))
  return live
end

local function apply(v, size, mask)
  local a = v.addr
  writeFloat(a + OFF.HalfExtents,     size)
  writeFloat(a + OFF.HalfExtents + 4, size)
  writeFloat(a + OFF.HalfExtents + 8, size)
  writeBytes(a + OFF.Enabled, 1)
  for idx, k in ipairs(ORDER) do writeBytes(a + OFF[k], mask[idx] or 0) end
end

function xrestore()
  local n = 0
  for _, v in ipairs(vols) do
    local a = v.addr
    pcall(writeFloat, a+OFF.HalfExtents,   v.orig.ext[1])
    pcall(writeFloat, a+OFF.HalfExtents+4, v.orig.ext[2])
    pcall(writeFloat, a+OFF.HalfExtents+8, v.orig.ext[3])
    for k, val in pairs(v.orig.bools) do if val ~= nil then pcall(writeBytes, a+OFF[k], val) end end
    n = n + 1
  end
  print(string.format("xrestore: all %d volume(s) restored", n))
end

-- grow exactly one volume, excluding HeaveUp only
function xsolo(i, size)
  size = size or 50000
  if not vols[i] then print("no such index"); return end
  xrestore()
  apply(vols[i], size, {0,1,0,0,0})
  print(string.format("xsolo: only #%d is active -> %s", i, dump(vols[i])))
  print("  try to mantle. if it blocks, this volume is the live one.")
end

-- grow every volume that has a referrer, excluding HeaveUp only
function xsololive(size)
  size = size or 50000
  xrestore()
  local n = 0
  for _, v in ipairs(vols) do
    if (v.refs or 0) > 0 then apply(v, size, {0,1,0,0,0}); n = n + 1 end
  end
  print(string.format("xsololive: %d referenced volume(s) set to block HeaveUp only", n))
  print("  try to mantle, then try to vault something low.")
end

function xstatus()
  local changed = {}
  for i, v in ipairs(vols) do
    local e = rf(v.addr + OFF.HalfExtents)
    if e and math.abs(e - (v.orig.ext[1] or 0)) > 0.01 then changed[#changed+1] = i end
  end
  print(string.format("%d of %d modified: %s", #changed, #vols, table.concat(changed, ", ")))
end

print("exclusion_step5 loaded. xlist() then xrefs().")
