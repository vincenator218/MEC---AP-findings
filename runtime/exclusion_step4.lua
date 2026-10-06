-- exclusion_step4.lua -- STEP 4: map each boolean to its move, using ONE volume
--
-- Step 3 proved the mechanism by growing all 62 volumes at once. That is too
-- blunt for a real client: 61 of those are the designers' own, gating specific
-- surfaces, and a randomizer should not be rewriting them.
--
-- So this step tests whether ONE volume is enough. We pick a single volume,
-- grow only that one to cover the map, and drive its five booleans. If that
-- works, the client design is "one AP control volume" and everything else in
-- the level is left untouched.
--
-- It also maps each boolean to the move it actually blocks, which is what the
-- world logic needs.
--
-- Functions:
--   xlist()                 scan and record (run after every load)
--   xpick(i)                choose the control volume (default: the largest)
--   xon(size)               grow ONLY the control volume, excluding nothing yet
--   xset(v,h,g,w,m)         set the five bools on the control volume (1/0, nil = leave)
--   xoff()                  restore the control volume only
--   xrestore()              restore every volume (safety net)
--   xstatus()               show the control volume and anything else modified

local BASE = getAddress("MirrorsEdgeCatalyst.exe")
local MODULE_SPAN = 0x4000000
local TI_ENTITYDATA = 0x2878C00
local OFF = { HalfExtents = 0x80, Enabled = 0x90,
              Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2, Wallrun = 0xA3, Magrope = 0xA4 }
local ORDER = { "Vault", "HeaveUp", "Hang", "Wallrun", "Magrope" }

local vols, ctrl = {}, nil
local function hx(v) return string.format("%X", v or 0) end
local function rq(a) local ok,v = pcall(readQword,a); if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a); if ok then return v end end

local function dump(v)
  local a = v.addr
  local b = {}
  for _, k in ipairs(ORDER) do b[#b+1] = k .. "=" .. tostring(rb(a+OFF[k])) end
  return string.format("%s  En=%s %s  ext=(%.1f, %.1f, %.1f)",
    hx(a), tostring(rb(a+OFF.Enabled)), table.concat(b, " "),
    rf(a+OFF.HalfExtents) or 0, rf(a+OFF.HalfExtents+4) or 0, rf(a+OFF.HalfExtents+8) or 0)
end

function xlist()
  vols, ctrl = {}, nil
  local ti = BASE + TI_ENTITYDATA
  local d = rq(ti + 0x20)
  local vt = d and rq(d)
  if not vt then print("no vtable -- game loaded?"); return end
  local pat, v = {}, vt
  for _ = 1, 8 do pat[#pat+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  local hits = AOBScan(table.concat(pat, " "), "+W", 0, 8)
  if not hits then print("no instances"); return end
  for i = 0, hits.getCount() - 1 do
    local a = tonumber(hits.getString(i), 16)
    if a ~= d and not (a >= BASE and a <= BASE + MODULE_SPAN) then
      local e1 = rf(a + OFF.HalfExtents)
      if e1 and e1 >= 0 and e1 < 100000 then
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

function xpick(i)
  if #vols == 0 then print("run xlist() first"); return end
  if not i then
    local best, bi = -1, nil
    for k, v in ipairs(vols) do
      local vol = (v.orig.ext[1] or 0) * (v.orig.ext[2] or 0) * (v.orig.ext[3] or 0)
      if vol > best then best, bi = vol, k end
    end
    i = bi
  end
  ctrl = i
  print(string.format("control volume = #%d  %s", i, dump(vols[i])))
  print("  its original values are recorded; xoff() puts just this one back.")
end

function xon(size)
  size = size or 2000
  if not ctrl then xpick() end
  if not ctrl then return end
  local a = vols[ctrl].addr
  writeFloat(a + OFF.HalfExtents,     size)
  writeFloat(a + OFF.HalfExtents + 4, size)
  writeFloat(a + OFF.HalfExtents + 8, size)
  writeBytes(a + OFF.Enabled, 1)
  for _, k in ipairs(ORDER) do writeBytes(a + OFF[k], 0) end
  print(string.format("xon: volume #%d grown to (%g,%g,%g), Enabled=1, excluding NOTHING.",
        ctrl, size, size, size))
  print("  -> everything should still work. Confirm that, then use xset().")
end

function xset(vault, heaveup, hang, wallrun, magrope)
  if not ctrl then print("run xon() first"); return end
  local a = vols[ctrl].addr
  local vals = { Vault = vault, HeaveUp = heaveup, Hang = hang, Wallrun = wallrun, Magrope = magrope }
  for _, k in ipairs(ORDER) do
    if vals[k] ~= nil then writeBytes(a + OFF[k], vals[k]) end
  end
  print("xset: " .. dump(vols[ctrl]))
end

function xoff()
  if not ctrl then print("no control volume chosen"); return end
  local v = vols[ctrl]
  local a = v.addr
  writeFloat(a + OFF.HalfExtents,     v.orig.ext[1])
  writeFloat(a + OFF.HalfExtents + 4, v.orig.ext[2])
  writeFloat(a + OFF.HalfExtents + 8, v.orig.ext[3])
  for k, val in pairs(v.orig.bools) do if val ~= nil then writeBytes(a + OFF[k], val) end end
  print("xoff: control volume #" .. ctrl .. " restored -> " .. dump(v))
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

function xstatus()
  if ctrl then print("control #" .. ctrl .. ": " .. dump(vols[ctrl])) end
  local changed = 0
  for i, v in ipairs(vols) do
    local e = rf(v.addr + OFF.HalfExtents)
    if e and math.abs(e - (v.orig.ext[1] or 0)) > 0.01 then changed = changed + 1 end
  end
  print(string.format("%d of %d volume(s) differ from their recorded original", changed, #vols))
end

print("exclusion_step4 loaded. xlist() then xpick() then xon().")
