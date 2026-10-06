-- exclusion_lab.lua -- movement exclusion volumes: the working toolkit
--
-- Supersedes exclusion_step3..step7. Same mechanism, but it remembers each
-- volume's originals across re-scans, validates every address before writing,
-- and can hold a mask in place while the level streams -- which is what a real
-- Archipelago client has to do.
--
-- Confirmed already (FINDINGS §84): the five bools are independent and each blocks
-- exactly one move. HalfExtents 2000 works, 50000 is silently ignored.
--
--   xlist()                    scan; keeps originals for volumes seen before
--   xapply(size, v,h,g,w,m)    grow every volume to size, set that mask on all
--   xrestore()                 put every volume ever seen back to its original
--   xinfo()                    counts, and how many currently hold our values
--   xauto(sec)                 hold the current mask through streaming (cheap:
--                              re-writes known addresses every tick, re-scans
--                              every 15s). This is the client prototype.
--   xstop()                    stop xauto
--   xvalid()                   which volumes are still valid (vtable intact)
--   xsolo(i, size, v,h,g,w,m)  mask ONE volume only, leave the other 60 alone
--   xhold(sec)                 keep one volume masked across streaming (CLIENT ALGORITHM)
--
-- Mask order is always (Vault, HeaveUp, Hang, Wallrun, Magrope); 1 = blocked.

local BASE = getAddress("MirrorsEdgeCatalyst.exe")
local MODULE_SPAN = 0x4000000
local TI = 0x2878C00                      -- PamMovementExclusionEntityData type info
local OFF = { Ext = 0x80, Enabled = 0x90,
              Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2, Wallrun = 0xA3, Magrope = 0xA4 }
local ORDER = { "Vault", "HeaveUp", "Hang", "Wallrun", "Magrope" }

-- known[addr] = { ext={x,y,z}, bools={...} }  -- originals, never overwritten once set
local known = known or {}
local live = {}                            -- addresses from the most recent scan
local cur = nil                            -- { size=, mask={...} }
local vtable = nil
local timer = nil

local function hx(v) return string.format("%X", v or 0) end
local function rq(a) local ok,v = pcall(readQword,a); if ok and v~=0 then return v end end
local function rb(a) local ok,v = pcall(readBytes,a,1,true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat,a); if ok then return v end end

local function get_vtable()
  local d = rq(BASE + TI + 0x20)
  local vt = d and rq(d)
  return vt, d
end

-- an address is still a volume only if its vtable is intact
local function valid(a)
  return vtable and rq(a) == vtable
end

function xlist()
  local vt, default_obj = get_vtable()
  if not vt then print("no vtable -- is the game loaded?"); return end
  vtable = vt
  local p, v = {}, vt
  for _ = 1, 8 do p[#p+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  local hits = AOBScan(table.concat(p, " "), "+W", 0, 8)
  if not hits then print("no instances found"); return end

  live = {}
  local newly = 0
  for i = 0, hits.getCount() - 1 do
    local a = tonumber(hits.getString(i), 16)
    if a ~= default_obj and not (a >= BASE and a <= BASE + MODULE_SPAN) then
      local e1 = rf(a + OFF.Ext)
      if e1 and e1 >= 0 and e1 < 1e6 then
        live[#live+1] = a
        if not known[a] then
          local o = { ext = { e1, rf(a+OFF.Ext+4), rf(a+OFF.Ext+8) }, bools = {} }
          o.bools.Enabled = rb(a + OFF.Enabled)
          for _, k in ipairs(ORDER) do o.bools[k] = rb(a + OFF[k]) end
          known[a] = o
          newly = newly + 1
        end
      end
    end
  end
  hits.destroy()
  local kn = 0; for _ in pairs(known) do kn = kn + 1 end
  print(string.format("xlist: %d volume(s) in memory (%d newly seen; %d known in total)",
        #live, newly, kn))
  return #live
end

local function write_one(a, size, mask)
  if not valid(a) then return false end
  pcall(writeFloat, a + OFF.Ext,     size)
  pcall(writeFloat, a + OFF.Ext + 4, size)
  pcall(writeFloat, a + OFF.Ext + 8, size)
  pcall(writeBytes, a + OFF.Enabled, 1)
  for i, k in ipairs(ORDER) do pcall(writeBytes, a + OFF[k], mask[i] or 0) end
  return true
end

function xapply(size, vault, heaveup, hang, wallrun, magrope)
  size = size or 2000
  if #live == 0 then xlist() end
  if #live == 0 then return end
  cur = { size = size, mask = { vault or 0, heaveup or 0, hang or 0, wallrun or 0, magrope or 0 } }
  local n = 0
  for _, a in ipairs(live) do if write_one(a, size, cur.mask) then n = n + 1 end end
  print(string.format("xapply: size=%g mask V=%d H=%d Hg=%d W=%d M=%d -> %d/%d volume(s)",
        size, cur.mask[1], cur.mask[2], cur.mask[3], cur.mask[4], cur.mask[5], n, #live))
end

function xrestore()
  local n = 0
  for a, o in pairs(known) do
    if valid(a) then
      pcall(writeFloat, a + OFF.Ext,     o.ext[1])
      pcall(writeFloat, a + OFF.Ext + 4, o.ext[2])
      pcall(writeFloat, a + OFF.Ext + 8, o.ext[3])
      for k, val in pairs(o.bools) do
        if val ~= nil then pcall(writeBytes, a + OFF[k], val) end
      end
      n = n + 1
    end
  end
  cur = nil
  print(string.format("xrestore: %d volume(s) restored (of %d known)", n,
        (function() local c=0; for _ in pairs(known) do c=c+1 end; return c end)()))
end

function xinfo()
  local kn = 0; for _ in pairs(known) do kn = kn + 1 end
  print(string.format("known=%d  in-memory=%d  vtable=%s", kn, #live, hx(vtable)))
  if not cur then print("  no mask applied"); return end
  local holding, stale = 0, 0
  for _, a in ipairs(live) do
    if valid(a) then
      local e = rf(a + OFF.Ext)
      if e and math.abs(e - cur.size) < 0.01 then holding = holding + 1 end
    else
      stale = stale + 1
    end
  end
  print(string.format("  mask size=%g V=%d H=%d Hg=%d W=%d M=%d",
        cur.size, cur.mask[1], cur.mask[2], cur.mask[3], cur.mask[4], cur.mask[5]))
  print(string.format("  %d/%d still hold our size, %d address(es) no longer valid",
        holding, #live, stale))
end

-- which of the in-memory volumes are still valid (vtable intact)?
function xvalid()
  local ok = {}
  for i, a in ipairs(live) do if valid(a) then ok[#ok+1] = i end end
  print(string.format("%d/%d volume(s) valid: %s", #ok, #live,
        table.concat(ok, ", ", 1, math.min(#ok, 40)) .. (#ok > 40 and " ..." or "")))
  return ok
end

-- restore everything, then mask exactly ONE valid volume.
-- If the block still applies, the client only needs one volume and can leave
-- the designers' other volumes alone entirely.
function xsolo(which, size, vault, heaveup, hang, wallrun, magrope)
  size = size or 20000
  local ok = {}
  for i, a in ipairs(live) do if valid(a) then ok[#ok+1] = i end end
  if #ok == 0 then print("no valid volumes; run xlist()"); return end
  local idx = which or ok[1]
  if not valid(live[idx] or 0) then
    print(string.format("volume #%d is not valid. valid ones: %s", idx,
          table.concat(ok, ", ", 1, math.min(#ok, 20))))
    return
  end
  xrestore()
  cur = { size = size, mask = { vault or 1, heaveup or 0, hang or 0, wallrun or 0, magrope or 0 } }
  write_one(live[idx], size, cur.mask)
  print(string.format("xsolo: ONLY volume #%d (%s) masked -> size=%g V=%d H=%d Hg=%d W=%d M=%d",
        idx, hx(live[idx]), size, cur.mask[1], cur.mask[2], cur.mask[3], cur.mask[4], cur.mask[5]))
  print("  the other " .. (#live - 1) .. " are at their authored values.")
  print("  -> try the move. if it blocks, one volume is enough.")
end

-- hold the mask through streaming. cheap: writes only, re-scans every 15s.
function xauto(sec)
  sec = sec or 2
  if not cur then print("apply a mask first with xapply()"); return end
  xstop()
  local ticks = 0
  timer = createTimer(nil)
  timer_setInterval(timer, math.floor(sec * 1000))
  timer_onTimer(timer, function()
    ticks = ticks + 1
    if ticks % math.max(1, math.floor(15 / sec)) == 0 then
      -- periodic re-scan picks up volumes the level has streamed in
      local before = #live
      xlist()
      if #live ~= before then
        print(string.format("  xauto: volume count changed %d -> %d", before, #live))
      end
    end
    local n = 0
    for _, a in ipairs(live) do if write_one(a, cur.size, cur.mask) then n = n + 1 end end
  end)
  timer_setEnabled(timer, true)
  print(string.format("xauto: holding the mask, re-writing every %gs, re-scanning every ~15s.", sec))
  print("  xstop() to stop. xrestore() after xstop().")
end

-- THE CLIENT ALGORITHM: keep exactly ONE volume masked, re-picking when the
-- level streams the chosen one out. Everything else stays at its authored values.
function xhold(sec)
  sec = sec or 2
  if not cur then print("set a mask first, e.g. xsolo(nil, 20000, 1,0,0,0,0)"); return end
  xstop()
  local chosen = nil
  for i, a in ipairs(live) do
    if valid(a) then
      local e = rf(a + OFF.Ext)
      if e and math.abs(e - cur.size) < 0.01 then chosen = a; break end
    end
  end
  local ticks, repicks = 0, 0
  timer = createTimer(nil)
  timer_setInterval(timer, math.floor(sec * 1000))
  timer_onTimer(timer, function()
    ticks = ticks + 1
    -- is our volume still there?
    if chosen and valid(chosen) then
      write_one(chosen, cur.size, cur.mask)   -- cheap: re-assert every tick
      return
    end
    -- it died. find another valid one, re-scanning if we have none left.
    local function pick()
      for _, a in ipairs(live) do if valid(a) then return a end end
    end
    local nxt = pick()
    if not nxt then
      xlist()
      nxt = pick()
    end
    if nxt then
      if chosen then
        local o = known[chosen]          -- best effort: it is probably gone
        if o and valid(chosen) then write_one(chosen, o.ext[1], {o.bools.Vault or 0,
          o.bools.HeaveUp or 0, o.bools.Hang or 0, o.bools.Wallrun or 0, o.bools.Magrope or 0}) end
      end
      chosen = nxt
      write_one(chosen, cur.size, cur.mask)
      repicks = repicks + 1
      print(string.format("  xhold: re-picked volume %s (repick #%d, tick %d)",
            hx(chosen), repicks, ticks))
    end
  end)
  timer_setEnabled(timer, true)
  print(string.format("xhold: maintaining ONE masked volume every %gs (start: %s)",
        sec, chosen and hx(chosen) or "none yet"))
  print("  now travel around and keep testing the move. xstop() then xrestore() when done.")
end

function xstop()
  if timer then
    timer_setEnabled(timer, false)
    object_destroy(timer)
    timer = nil
    print("xauto stopped.")
  end
end

print("exclusion_lab loaded. xlist() then xapply(2000, 1,0,0,0,0).")
