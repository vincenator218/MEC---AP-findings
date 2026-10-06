-- exclusion_step7.lua -- STEP 7: separate the two variables (size vs which flag)
--
-- Step 3  : all volumes, size 2000, ORIGINAL flags (V+H+Hg+W mostly all 1) -> mantle BLOCKED
-- Step 6  : all volumes, size 50000, HeaveUp only                          -> mantle WORKS
--
-- Two things changed at once, so either
--   (a) the mantle is blocked by a different flag than ExcludeHeaveUp, or
--   (b) 50000 is too large and the volume test fails at that size.
--
-- This script makes size and the flag mask independent so we can pin it down.
--
--   xlist()                      one scan (re-run after any load)
--   xreplay(size)                grow all, keep each volume's ORIGINAL flags
--                                  -> xreplay(2000) should reproduce step 3 exactly
--   xgo(size, v,h,g,w,m)         grow all to size, set that mask on all
--   xrange(lo,hi,size, v,h,g,w,m)  same but only volumes lo..hi
--   xrestore()                   put everything back
--   xstatus()                    what is currently modified

local BASE = getAddress("MirrorsEdgeCatalyst.exe")
local MODULE_SPAN = 0x4000000
local TI_ENTITYDATA = 0x2878C00
local OFF = { HalfExtents = 0x80, Enabled = 0x90,
              Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2, Wallrun = 0xA3, Magrope = 0xA4 }
local ORDER = { "Vault", "HeaveUp", "Hang", "Wallrun", "Magrope" }

local vols = {}
local function rq(a) local ok,v = pcall(readQword,a); if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a); if ok then return v end end

function xlist()
  vols = {}
  local d = rq(BASE + TI_ENTITYDATA + 0x20)
  local vt = d and rq(d)
  if not vt then print("no vtable -- game loaded?"); return end
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
  print(string.format("xlist: %d volume(s) recorded", #vols))
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
  print(string.format("xrestore: %d volume(s) back to original", #vols))
end

-- grow only; every flag left exactly as the level authored it
function xreplay(size)
  size = size or 2000
  if #vols == 0 then print("run xlist() first"); return end
  xrestore()
  for _, v in ipairs(vols) do
    local a = v.addr
    pcall(writeFloat, a + OFF.HalfExtents,     size)
    pcall(writeFloat, a + OFF.HalfExtents + 4, size)
    pcall(writeFloat, a + OFF.HalfExtents + 8, size)
  end
  print(string.format("xreplay: all %d volume(s) grown to %g, ORIGINAL flags untouched.", #vols, size))
  print("  this is step 3 exactly. mantle should block. if it does NOT, the size is the problem.")
end

function xrange(lo, hi, size, vault, heaveup, hang, wallrun, magrope)
  if #vols == 0 then print("run xlist() first"); return end
  size = size or 2000
  lo = math.max(1, lo or 1); hi = math.min(#vols, hi or #vols)
  local m = { vault or 0, heaveup or 0, hang or 0, wallrun or 0, magrope or 0 }
  xrestore()
  for i = lo, hi do
    local a = vols[i].addr
    pcall(writeFloat, a + OFF.HalfExtents,     size)
    pcall(writeFloat, a + OFF.HalfExtents + 4, size)
    pcall(writeFloat, a + OFF.HalfExtents + 8, size)
    pcall(writeBytes, a + OFF.Enabled, 1)
    for idx, k in ipairs(ORDER) do pcall(writeBytes, a + OFF[k], m[idx]) end
  end
  print(string.format("xrange: %d..%d at size %g, mask V=%d H=%d Hg=%d W=%d M=%d",
        lo, hi, size, m[1], m[2], m[3], m[4], m[5]))
end

function xgo(size, vault, heaveup, hang, wallrun, magrope)
  xrange(1, #vols, size, vault, heaveup, hang, wallrun, magrope)
end

function xstatus()
  local ch = {}
  for i, v in ipairs(vols) do
    local e = rf(v.addr + OFF.HalfExtents)
    if e and math.abs(e - (v.orig.ext[1] or 0)) > 0.01 then ch[#ch+1] = i end
  end
  print(string.format("%d/%d modified: %s", #ch, #vols, table.concat(ch, ", ")))
  if vols[1] then
    local a = vols[1].addr
    local b = {}
    for _, k in ipairs(ORDER) do b[#b+1] = k .. "=" .. tostring(rb(a+OFF[k])) end
    print("  #1 now: " .. table.concat(b, " ") ..
      string.format("  ext=%.0f", rf(a+OFF.HalfExtents) or 0))
  end
end

print("exclusion_step7 loaded. xlist() then xreplay(2000).")
