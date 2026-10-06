-- exclusion_step6.lua -- STEP 6: find the live volume by bisection (cheap)
--
-- Forget xrefs() -- 61 memory scans was far too heavy. Bisection finds the same
-- answer with ONE scan and then nothing but writes.
--
-- Idea: step 3 proved that growing all of them blocks the mantle. So at least one
-- volume in the set governs the player. Grow half; if the mantle still blocks, the
-- live one is in that half; if not, it's in the other. Six rounds narrows 61 to 1.
--
-- Usage:
--   xlist()            one scan, records every volume (re-run after any load)
--   xtest(lo, hi)      restore all, then grow ONLY volumes lo..hi, HeaveUp only
--                      -> then try to mantle and tell me blocked / not blocked
--   xall()             restore all, then grow ALL, HeaveUp only  (the step 3 control)
--   xmask(v,h,g,w,m)   change which bools the currently grown volumes exclude
--   xrestore()         put everything back
--   xstatus()          which indices are currently modified
--
-- Suggested rounds (61 volumes):
--   xtest(1,31)   blocked? -> xtest(1,15)    not blocked? -> xtest(32,61)
--   ...keep halving. ~6 tries.

local BASE = getAddress("MirrorsEdgeCatalyst.exe")
local MODULE_SPAN = 0x4000000
local TI_ENTITYDATA = 0x2878C00
local OFF = { HalfExtents = 0x80, Enabled = 0x90,
              Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2, Wallrun = 0xA3, Magrope = 0xA4 }
local ORDER = { "Vault", "HeaveUp", "Hang", "Wallrun", "Magrope" }
local SIZE = 50000

local vols, grown = {}, {}
local function hx(v) return string.format("%X", v or 0) end
local function rq(a) local ok,v = pcall(readQword,a); if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a); if ok then return v end end

function xlist()
  vols, grown = {}, {}
  local d = rq(BASE + TI_ENTITYDATA + 0x20)
  local vt = d and rq(d)
  if not vt then print("no vtable -- is the game loaded?"); return end
  local p, v = {}, vt
  for _ = 1, 8 do p[#p+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  local hits = AOBScan(table.concat(p, " "), "+W", 0, 8)
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
  print(string.format("xlist: %d volume(s) recorded (1..%d)", #vols, #vols))
  return #vols
end

function xrestore()
  for _, v in ipairs(vols) do
    local a = v.addr
    pcall(writeFloat, a+OFF.HalfExtents,   v.orig.ext[1])
    pcall(writeFloat, a+OFF.HalfExtents+4, v.orig.ext[2])
    pcall(writeFloat, a+OFF.HalfExtents+8, v.orig.ext[3])
    for k, val in pairs(v.orig.bools) do if val ~= nil then pcall(writeBytes, a+OFF[k], val) end end
  end
  grown = {}
  print(string.format("xrestore: %d volume(s) back to original", #vols))
end

local function grow(i, mask)
  local a = vols[i].addr
  pcall(writeFloat, a + OFF.HalfExtents,     SIZE)
  pcall(writeFloat, a + OFF.HalfExtents + 4, SIZE)
  pcall(writeFloat, a + OFF.HalfExtents + 8, SIZE)
  pcall(writeBytes, a + OFF.Enabled, 1)
  for idx, k in ipairs(ORDER) do pcall(writeBytes, a + OFF[k], mask[idx] or 0) end
end

function xtest(lo, hi)
  if #vols == 0 then print("run xlist() first"); return end
  lo = math.max(1, lo or 1); hi = math.min(#vols, hi or #vols)
  xrestore()
  grown = {}
  for i = lo, hi do grow(i, {0,1,0,0,0}); grown[#grown+1] = i end
  print(string.format("xtest: volumes %d..%d grown to %g, excluding HeaveUp only (%d volumes)",
        lo, hi, SIZE, #grown))
  print("  -> try to mantle. blocked = the live volume is in this range.")
end

function xall()
  xtest(1, #vols)
end

function xmask(vault, heaveup, hang, wallrun, magrope)
  if #grown == 0 then print("nothing is grown; run xtest() first"); return end
  local m = { vault, heaveup, hang, wallrun, magrope }
  for _, i in ipairs(grown) do
    for idx, k in ipairs(ORDER) do
      if m[idx] ~= nil then pcall(writeBytes, vols[i].addr + OFF[k], m[idx]) end
    end
  end
  print(string.format("xmask: V=%s H=%s Hg=%s W=%s M=%s on %d grown volume(s)",
        tostring(vault), tostring(heaveup), tostring(hang),
        tostring(wallrun), tostring(magrope), #grown))
end

function xstatus()
  local ch = {}
  for i, v in ipairs(vols) do
    local e = rf(v.addr + OFF.HalfExtents)
    if e and math.abs(e - (v.orig.ext[1] or 0)) > 0.01 then ch[#ch+1] = i end
  end
  print(string.format("%d/%d modified: %s", #ch, #vols, table.concat(ch, ", ")))
end

print("exclusion_step6 loaded. xlist() then xall() to re-confirm, then bisect with xtest(lo,hi).")
