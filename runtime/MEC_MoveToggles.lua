--[[===========================================================================
  Mirror's Edge Catalyst -- Movement Toggles
  For the Archipelago randomizer project. Lets you remove individual movement
  moves so we can work out which missions and activities actually need them.

  HOW TO USE
    1. Start the game and load a save (any save, free roam is fine).
    2. Open Cheat Engine. You do NOT need to attach it yourself.
    3. Ctrl+Alt+L to open the Lua window, paste this whole file, press Execute.
    4. A small window appears. Click a move to remove it; click again to give
       it back. Then go try a mission.

  IS THIS SAFE?
    Yes. It changes nothing in your save file. These moves are controlled by
    invisible "exclusion volumes" the level designers placed to stop you
    climbing certain surfaces, and this just borrows one of them. Nothing is
    written to disk, and closing the window or restarting the game puts
    everything back.

  WHAT TO REPORT
    For each mission / side mission / run: which moves you HAD to have to
    finish it. "Nothing needed" is a real and useful answer. Select the log
    with Ctrl+A, copy with Ctrl+C, and paste it with your notes.

  Not covered by this tool: pipes, ladders, and ordinary jumping. Those cannot
  be removed, so a mission that only needs those will always be completable.
===========================================================================]]--

local PROCESS = "MirrorsEdgeCatalyst.exe"
local TI      = 0x2878C00     -- PamMovementExclusionEntityData type info
local OFF     = { Ext = 0x80, Enabled = 0x90,
                  Vault = 0xA0, HeaveUp = 0xA1, Hang = 0xA2,
                  Wallrun = 0xA3, Magrope = 0xA4 }
local ORDER   = { "Vault", "HeaveUp", "Hang", "Wallrun", "Magrope" }
local LABEL   = { Vault = "Springboard / Vault", HeaveUp = "Climb Up (mantle)",
                  Hang  = "Ledge Hang",          Wallrun = "Wallrun",
                  Magrope = "MAG Rope" }
local SIZE    = 20000         -- 20000 works; 50000 is silently ignored
local BIG      = 100          -- authored extents are tiny, so >100 means "ours"

local BASE                    -- module base
local vtable                  -- shared vtable of every volume instance
local chosen                  -- the volume we are driving
local originals = {}          -- addr -> { ext, bools } captured before we touch it
local removed = { Vault=false, HeaveUp=false, Hang=false, Wallrun=false, Magrope=false }

local form, memo, status, buttons, timer = nil, nil, nil, {}, nil

---------------------------------------------------------------------- helpers
local function log(fmt, ...)
  local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
  local line = os.date("[%H:%M:%S] ") .. msg
  if memo then
    local ok = pcall(function() memo.Lines.add(line) end)
    if not ok then pcall(function() memo.Text = memo.Text .. line .. "\n" end) end
  end
  print(line)
end

local function rq(a) local ok,v = pcall(readQword, a); if ok and v ~= 0 then return v end end
local function rb(a) local ok,v = pcall(readBytes, a, 1, true); if ok and v then return v[1] end end
local function rf(a) local ok,v = pcall(readFloat, a); if ok then return v end end

local function anything_removed()
  for _, k in ipairs(ORDER) do if removed[k] then return true end end
  return false
end

-- a remembered address is only still a volume if its vtable is intact
local function valid(a)
  return a and vtable and rq(a) == vtable
end

---------------------------------------------------------------- game plumbing
local function attach()
  if getOpenedProcessID() == 0 or not readInteger(getAddress(PROCESS) or 0) then
    local ok = pcall(openProcess, PROCESS)
    if not ok then return false, "Could not attach to the game." end
  end
  local ok, b = pcall(getAddress, PROCESS)
  if not ok or not b then return false, "Game not found. Start it and load a save." end
  BASE = b
  local d = rq(BASE + TI + 0x20)             -- the class's default object
  local vt = d and rq(d)                     -- its first qword is the shared vtable
  if not vt then
    return false, "Game found, but not loaded in yet. Load a save, then press Rescan."
  end
  vtable = vt
  return true
end

-- every instance of the class, found by scanning for pointers to its vtable
local function scan()
  if not vtable then return {} end
  local pat, v = {}, vtable
  for _ = 1, 8 do pat[#pat+1] = string.format("%02X", v & 0xFF); v = v >> 8 end
  local hits = AOBScan(table.concat(pat, " "), "+W", 0, 8)
  if not hits then return {} end
  local out = {}
  local module_end = BASE + 0x4000000
  local default_obj = rq(BASE + TI + 0x20)
  for i = 0, hits.getCount() - 1 do
    local a = tonumber(hits.getString(i), 16)
    if a ~= default_obj and not (a >= BASE and a <= module_end) then
      local e = rf(a + OFF.Ext)
      if e and e >= 0 and e < 1e6 then out[#out+1] = a end
    end
  end
  hits.destroy()
  return out
end

local function remember(a)
  if originals[a] then return end
  local o = { ext = { rf(a+OFF.Ext), rf(a+OFF.Ext+4), rf(a+OFF.Ext+8) }, bools = {} }
  if o.ext[1] and o.ext[1] > BIG then return end   -- already one of ours; don't record
  o.bools.Enabled = rb(a + OFF.Enabled)
  for _, k in ipairs(ORDER) do o.bools[k] = rb(a + OFF[k]) end
  originals[a] = o
end

local function write_mask(a)
  if not valid(a) then return false end
  pcall(writeFloat, a + OFF.Ext,     SIZE)
  pcall(writeFloat, a + OFF.Ext + 4, SIZE)
  pcall(writeFloat, a + OFF.Ext + 8, SIZE)
  pcall(writeBytes, a + OFF.Enabled, 1)
  for _, k in ipairs(ORDER) do
    pcall(writeBytes, a + OFF[k], removed[k] and 1 or 0)
  end
  return true
end

-- put a volume back. If we never recorded its original, make it harmless
-- instead: the level restores the real values next time it streams it in.
local function release_one(a)
  if not valid(a) then return end
  local o = originals[a]
  if o and o.ext[1] and o.ext[1] <= BIG then
    pcall(writeFloat, a + OFF.Ext,     o.ext[1])
    pcall(writeFloat, a + OFF.Ext + 4, o.ext[2])
    pcall(writeFloat, a + OFF.Ext + 8, o.ext[3])
    for k, v in pairs(o.bools) do
      if v ~= nil then pcall(writeBytes, a + OFF[k], v) end
    end
  else
    for _, k in ipairs(ORDER) do pcall(writeBytes, a + OFF[k], 0) end
    pcall(writeFloat, a + OFF.Ext,     1)
    pcall(writeFloat, a + OFF.Ext + 4, 1)
    pcall(writeFloat, a + OFF.Ext + 8, 1)
  end
end

-- release anything still carrying our signature, whether we remember it or not
local function release_all()
  local n = 0
  for _, a in ipairs(scan()) do
    local e = rf(a + OFF.Ext)
    if e and e > BIG then release_one(a); n = n + 1 end
  end
  chosen = nil
  return n
end

------------------------------------------------------------------------- state
local function refresh_buttons()
  for _, k in ipairs(ORDER) do
    local b = buttons[k]
    if b then
      b.Caption = (removed[k] and "\xE2\x9C\x98  " or "\xE2\x9C\x93  ") .. LABEL[k]
                  .. (removed[k] and "  --  REMOVED" or "  --  you have it")
    end
  end
end

local function set_status(text)
  if status then status.Caption = text end
end

-- make the game match `removed`
local function apply()
  if not vtable then
    local ok, err = attach()
    if not ok then set_status(err); log(err); return end
  end

  if not anything_removed() then
    local n = release_all()
    set_status("All moves available. Nothing is modified.")
    if n > 0 then log("Released %d volume(s). Everything back to normal.", n) end
    return
  end

  if not valid(chosen) then
    local list = scan()
    chosen = nil
    for _, a in ipairs(list) do
      if valid(a) then remember(a); chosen = a; break end
    end
    if not chosen then
      set_status("No exclusion volume found. Load into the world and press Rescan.")
      log("Could not find a volume to use. Are you loaded into the game world?")
      return
    end
    log("Using volume %X (of %d found).", chosen, #list)
  end

  write_mask(chosen)
  local gone = {}
  for _, k in ipairs(ORDER) do if removed[k] then gone[#gone+1] = LABEL[k] end end
  set_status("Removed: " .. table.concat(gone, ", "))
end

local function toggle(key)
  removed[key] = not removed[key]
  log("%s -> %s", LABEL[key], removed[key] and "REMOVED" or "available")
  refresh_buttons()
  apply()
end

----------------------------------------------------------------- the hold loop
-- Volumes stream in and out with the level, so the one we picked will
-- eventually disappear. Re-assert it, and pick another when it does.
local function tick()
  if not anything_removed() then return end
  if valid(chosen) then
    write_mask(chosen)
    return
  end
  local list = scan()
  for _, a in ipairs(list) do
    if valid(a) then
      remember(a)
      chosen = a
      write_mask(a)
      log("The volume we were using unloaded; switched to %X. Still working.", a)
      return
    end
  end
  set_status("Lost track of the volume -- press Rescan.")
end

------------------------------------------------------------------------- the UI
local function build()
  form = createForm(true)
  form.Caption = "Mirror's Edge Catalyst -- Movement Toggles"
  form.Width, form.Height = 520, 470
  form.BorderStyle = bsSingle
  pcall(function() form.Position = poScreenCenter end)

  local head = createLabel(form)
  head.Left, head.Top, head.Width = 14, 10, 490
  head.Caption = "Click a move to remove it. Click again to give it back."
  pcall(function() head.Font.Style = "fsBold" end)

  local sub = createLabel(form)
  sub.Left, sub.Top, sub.Width = 14, 30, 490
  sub.Caption = "Your save is never touched. Closing this window undoes everything."

  local y = 56
  for _, k in ipairs(ORDER) do
    local b = createButton(form)
    b.Left, b.Top, b.Width, b.Height = 14, y, 300, 30
    b.OnClick = function() toggle(k) end
    buttons[k] = b
    y = y + 34
  end

  local ball = createButton(form)
  ball.Left, ball.Top, ball.Width, ball.Height = 324, 56, 180, 30
  ball.Caption = "Remove ALL moves"
  ball.OnClick = function()
    for _, k in ipairs(ORDER) do removed[k] = true end
    log("Removed every move.")
    refresh_buttons(); apply()
  end

  local nall = createButton(form)
  nall.Left, nall.Top, nall.Width, nall.Height = 324, 90, 180, 30
  nall.Caption = "Give back ALL moves"
  nall.OnClick = function()
    for _, k in ipairs(ORDER) do removed[k] = false end
    log("Gave every move back.")
    refresh_buttons(); apply()
  end

  local rescan = createButton(form)
  rescan.Left, rescan.Top, rescan.Width, rescan.Height = 324, 124, 180, 30
  rescan.Caption = "Rescan"
  rescan.OnClick = function()
    chosen = nil
    local ok, err = attach()
    if not ok then set_status(err); log(err); return end
    local list = scan()
    log("Rescan: %d volume(s) found.", #list)
    apply()
  end

  local reset = createButton(form)
  reset.Left, reset.Top, reset.Width, reset.Height = 324, 158, 180, 30
  reset.Caption = "Reset everything"
  reset.OnClick = function()
    for _, k in ipairs(ORDER) do removed[k] = false end
    local n = release_all()
    refresh_buttons()
    log("Reset: released %d volume(s). Every move is back.", n)
    set_status("All moves available. Nothing is modified.")
  end

  status = createLabel(form)
  status.Left, status.Top, status.Width = 14, 234, 490
  status.Caption = "Starting up..."

  local loglbl = createLabel(form)
  loglbl.Left, loglbl.Top, loglbl.Width = 14, 258, 490
  loglbl.Caption = "Log -- click in it, Ctrl+A, Ctrl+C to copy for your report:"

  memo = createMemo(form)
  memo.Left, memo.Top, memo.Width, memo.Height = 14, 278, 490, 150
  memo.ReadOnly = true
  pcall(function() memo.ScrollBars = ssVertical end)
  pcall(function() memo.WordWrap = true end)

  form.OnClose = function()
    if timer then pcall(function() timer.Enabled = false end) end
    for _, k in ipairs(ORDER) do removed[k] = false end
    local n = release_all()
    log("Closed. Released %d volume(s).", n)
    return caFree
  end

  refresh_buttons()
end

--------------------------------------------------------------------------- go
build()
log("Movement Toggles ready.")

local ok, err = attach()
if ok then
  local list = scan()
  log("Attached. Found %d movement volume(s) in memory.", #list)
  if #list == 0 then
    set_status("Game found but no volumes yet -- load into the world, then Rescan.")
  else
    set_status("All moves available. Nothing is modified.")
  end
else
  log(err)
  set_status(err)
end

timer = createTimer(form)
pcall(function() timer.Interval = 2000 end)
timer.OnTimer = function() pcall(tick) end
pcall(function() timer.Enabled = true end)
