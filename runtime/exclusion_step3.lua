-- exclusion_step3.lua -- STEP 3: does editing a volume actually change movement?
--
-- THIS ONE WRITES to game memory. It does NOT touch any progression flag, so
-- nothing here can be captured by an autosave -- movement exclusion volumes are
-- level data, not save data. Still: every original value is recorded and can be
-- put back with xrestore().
--
-- Load this once, then call the functions from the Lua window.
--
--   xlist()           re-scan and list the volumes (do this first, and after any load)
--   xshow(i)          print one volume
--   xgrowall(n)       set EVERY volume's HalfExtents to (n,n,n)   <-- the main test
--   xrestore()        put every value back exactly as it was
--   xflagsall(v,h,g,w,m)   set the five Exclude bools on every volume (1/0 each)
--   xcount()          how many are currently modified
--
-- Test order is in the chat message. Read it before running anything.

local BASE = getAddress("MirrorsEdgeCatalyst.exe")
local MODULE_SPAN = 0x4000000        -- anything inside this is module data, not an instance
local TI_ENTITYDATA = 0x2878C00

local OFF = { HalfExtents = 0x80, Enabled = 0x90,
              Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2, Wallrun = 0xA3, Magrope = 0xA4 }

local vols = {}        -- { addr = ..., orig = {ext={x,y,z}, bools={...}} }
local function hx(v) return string.format("%X", v or 0) end
local function rq(a) local ok,v = pcall(readQword,a); if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a); if ok then return v end end

local function dump(v)
  local a = v.addr
  return string.format("%s  En=%s V=%s H=%s Hg=%s W=%s M=%s  ext=(%.1f, %.1f, %.1f)",
    hx(a), tostring(rb(a+OFF.Enabled)), tostring(rb(a+OFF.Vault)),
    tostring(rb(a+OFF.HeaveUp)), tostring(rb(a+OFF.Hang)),
    tostring(rb(a+OFF.Wallrun)), tostring(rb(a+OFF.Magrope)),
    rf(a+OFF.HalfExtents) or 0, rf(a+OFF.HalfExtents+4) or 0, rf(a+OFF.HalfExtents+8) or 0)
end

function xlist()
  vols = {}
  local ti = BASE + TI_ENTITYDATA
  local default_obj = rq(ti + 0x20)
  local vtable = default_obj and rq(default_obj)
  if not vtable then print("could not derive the vtable -- is the game loaded?"); return end

  local pat, v = {}, vtable
  for _ = 1, 8 do pat[#pat+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  local hits = AOBScan(table.concat(pat, " "), "+W", 0, 8)
  if not hits then print("no instances found"); return end

  for i = 0, hits.getCount() - 1 do
    local a = tonumber(hits.getString(i), 16)
    local in_module = (a >= BASE and a <= BASE + MODULE_SPAN)
    if a ~= default_obj and not in_module then
      local ext = { rf(a+OFF.HalfExtents), rf(a+OFF.HalfExtents+4), rf(a+OFF.HalfExtents+8) }
      -- sanity: a real volume has finite, non-silly extents
      if ext[1] and ext[1] >= 0 and ext[1] < 100000 then
        vols[#vols+1] = { addr = a, orig = { ext = ext, bools = {
          Enabled = rb(a+OFF.Enabled), Vault = rb(a+OFF.Vault), HeaveUp = rb(a+OFF.HeaveUp),
          Hang = rb(a+OFF.Hang), Wallrun = rb(a+OFF.Wallrun), Magrope = rb(a+OFF.Magrope) } } }
      end
    end
  end
  hits.destroy()
  print(string.format("xlist: %d placed volume(s) recorded (vtable %s)", #vols, hx(vtable)))
  local big = 0
  for i, vv in ipairs(vols) do if vv.orig.ext[1] > vols[big == 0 and i or big].orig.ext[1] then big = i end end
  if big > 0 then print("  largest is #" .. big .. ": " .. dump(vols[big])) end
  return #vols
end

function xshow(i)
  local v = vols[i]
  if not v then print("no such index; run xlist() first"); return end
  print(string.format("[%d] %s", i, dump(v)))
end

function xgrowall(n)
  n = n or 2000
  if #vols == 0 then print("run xlist() first"); return end
  local ok = 0
  for _, v in ipairs(vols) do
    local a = v.addr + OFF.HalfExtents
    if pcall(writeFloat, a, n) and pcall(writeFloat, a+4, n) and pcall(writeFloat, a+8, n) then
      ok = ok + 1
    end
  end
  print(string.format("xgrowall: set HalfExtents=(%g,%g,%g) on %d/%d volumes", n, n, n, ok, #vols))
  print("  now go try to climb / vault something. xrestore() puts it all back.")
end

function xflagsall(vault, heaveup, hang, wallrun, magrope)
  if #vols == 0 then print("run xlist() first"); return end
  local set = { Vault = vault, HeaveUp = heaveup, Hang = hang, Wallrun = wallrun, Magrope = magrope }
  local n = 0
  for _, v in ipairs(vols) do
    for k, val in pairs(set) do
      if val ~= nil then pcall(writeBytes, v.addr + OFF[k], val) end
    end
    n = n + 1
  end
  print(string.format("xflagsall: applied to %d volumes (V=%s H=%s Hg=%s W=%s M=%s)",
        n, tostring(vault), tostring(heaveup), tostring(hang), tostring(wallrun), tostring(magrope)))
end

function xrestore()
  if #vols == 0 then print("nothing recorded"); return end
  local n = 0
  for _, v in ipairs(vols) do
    local a = v.addr
    pcall(writeFloat, a+OFF.HalfExtents,   v.orig.ext[1])
    pcall(writeFloat, a+OFF.HalfExtents+4, v.orig.ext[2])
    pcall(writeFloat, a+OFF.HalfExtents+8, v.orig.ext[3])
    for k, val in pairs(v.orig.bools) do
      if val ~= nil then pcall(writeBytes, a + OFF[k], val) end
    end
    n = n + 1
  end
  print(string.format("xrestore: %d volume(s) put back to their original values", n))
end

function xcount()
  local changed = 0
  for _, v in ipairs(vols) do
    local e = rf(v.addr + OFF.HalfExtents)
    if e and math.abs(e - v.orig.ext[1]) > 0.01 then changed = changed + 1 end
  end
  print(string.format("%d of %d volume(s) currently differ from their recorded original", changed, #vols))
end

print("exclusion_step3 loaded. call xlist() first.")
print("IMPORTANT: xrestore() before you reload, quit, or walk away.")
