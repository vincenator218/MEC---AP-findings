-- opportunities.lua -- can an Opportunity be hidden/shown by its flag?
--
-- Table writes only. No game-function calls (those are what crashed the game).
--
-- Each opportunity has:  <name>_Available , <name>_CompletedTime , <name>_Timer
-- and a completion flag:  MiscCompleted_<name>  (opportunities)
--                         BronzeCompleted_<name> (deliveries)
--
-- op()              list all 58 (40 opportunities + 18 deliveries): Avail / Done / Time
-- opavail(i, v)     set entry i's _Available to v
-- opallavail(v)     set _Available = v on every entry that is currently 1
--                   (use v = 0 to try to hide them all at once)
-- opdone(i, v)      set entry i's COMPLETION flag (MiscCompleted_ / BronzeCompleted_)
--                   without touching its _CompletedTime. v = 1 marks it "done".
-- oprestore()       put every _Available AND every completion flag back to the
--                   value it had when this script was first executed
--
-- TEST A (does the completion flag put it in the Runs menu, like side missions?)
--   1. Paste, Execute.  Pick a row with Avail 0 and Done 0, e.g. 24.
--   2. opdone(24, 1)
--   3. Restart from checkpoint, then look in the menu (Runs / Opportunities).
--      A new entry with NO completion time = the flag is the menu gate.
--   4. oprestore()  then op()  -- must report OK before you die or linger.
--
-- TEST B (the old _Available test, already done: the map ignores it)
--   1. Paste, Execute. Note which entries show Avail = 1.
--   2. Open the map, count the opportunity markers in the district you're in.
--   3. opallavail(0)   -> close the map fully, reopen it, look again.
--   4. If nothing changed: restart from checkpoint, look again (the side-mission
--      menu only rebuilds at load, so the map may be the same).
--   5. oprestore()  then op()  -- confirm every value is back BEFORE you die,
--      reach a checkpoint, or leave it sitting (an autosave can catch it).

local OPPS = {}
for _, d in ipairs({ { "AncPh4", 8 }, { "AncPh5", 6 }, { "CtPh6", 6 }, { "DtPh2", 6 }, { "DtPh3", 8 }, { "VwPh7", 6 } }) do
  for i = 1, d[2] do OPPS[#OPPS + 1] = { name = string.format("OW Opp %s %02d", d[1], i), kind = "Misc" } end
end
for ph = 2, 7 do
  for k = 1, 3 do OPPS[#OPPS + 1] = { name = string.format("OWPh%dDelivery0%d", ph, k), kind = "Bronze" } end
end

local function djb2a(s)
  local h = 5381
  for i = 1, #s do h = ((h * 33) ~ s:byte(i)) & 0xFFFFFFFF end
  return h
end

local function node(h)
  local B = getAddress("MirrorsEdgeCatalyst.exe")
  local t = readQword(B + 0x257C9D8)
  local nb = readInteger(t + 0x28)
  local n = readQword(readQword(t + 0x20) + (h % nb) * 8)
  while n and n ~= 0 do
    if (readInteger(n) & 0xFFFFFFFF) == h then return n end
    n = readQword(n + 0x28)
  end
end

local function val(name)
  local n = node(djb2a(name))
  return n and readInteger(n + 0x18) or nil
end

local function setval(name, v)
  local n = node(djb2a(name))
  if not n then print("not in table: " .. name) return false end
  writeInteger(n + 0x18, v)
  return true
end

local function donename(o) return (o.kind == "Misc" and "MiscCompleted_" or "BronzeCompleted_") .. o.name end

OP_ORIGINAL = OP_ORIGINAL or {}       -- _Available at load
OP_ORIG_DONE = OP_ORIG_DONE or {}     -- completion flag at load
for i, o in ipairs(OPPS) do
  if OP_ORIGINAL[i] == nil then OP_ORIGINAL[i] = val(o.name .. "_Available") end
  if OP_ORIG_DONE[i] == nil then OP_ORIG_DONE[i] = val(donename(o)) end
end

function opdone(i, v)
  local o = OPPS[i]
  if not o then print("no entry " .. tostring(i)) return end
  local n = donename(o)
  local old = val(n)
  if setval(n, v) then
    print(string.format("%s: %s -> %d   (its _CompletedTime is %s, untouched)", n, tostring(old), v,
      tostring(val(o.name .. "_CompletedTime"))))
  end
end

function op()
  print(" #  Avail  Done  CompletedTime  name")
  for i, o in ipairs(OPPS) do
    local done = val((o.kind == "Misc" and "MiscCompleted_" or "BronzeCompleted_") .. o.name)
    print(string.format("%2d  %-5s  %-4s  %-13s  %s", i, tostring(val(o.name .. "_Available")),
      tostring(done), tostring(val(o.name .. "_CompletedTime")), o.name))
  end
end

function opavail(i, v)
  local o = OPPS[i]
  if not o then print("no entry " .. tostring(i)) return end
  local old = val(o.name .. "_Available")
  if setval(o.name .. "_Available", v) then
    print(string.format("%s_Available: %s -> %d", o.name, tostring(old), v))
  end
end

function opallavail(v)
  local n = 0
  for i, o in ipairs(OPPS) do
    if OP_ORIGINAL[i] == 1 then setval(o.name .. "_Available", v); n = n + 1 end
  end
  print(string.format("set _Available = %d on %d entries that were 1. Check the map.", v, n))
end

function oprestore()
  local n = 0
  for i, o in ipairs(OPPS) do
    if OP_ORIGINAL[i] ~= nil and val(o.name .. "_Available") ~= OP_ORIGINAL[i] then
      setval(o.name .. "_Available", OP_ORIGINAL[i]); n = n + 1
    end
    if OP_ORIG_DONE[i] ~= nil and val(donename(o)) ~= OP_ORIG_DONE[i] then
      setval(donename(o), OP_ORIG_DONE[i]); n = n + 1
    end
  end
  local ok = true
  for i, o in ipairs(OPPS) do
    if val(o.name .. "_Available") ~= OP_ORIGINAL[i] then ok = false end
    if val(donename(o)) ~= OP_ORIG_DONE[i] then ok = false end
  end
  print(string.format("restored %d values -- %s", n, ok and "OK, safe to die" or "!! NOT fully restored, send this output"))
end

op()
print("op() / opavail(i, v) / opallavail(v) / opdone(i, v) / oprestore()")
