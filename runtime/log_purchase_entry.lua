-- log_purchase_entry.lua
--
-- Completes the step named at the end of §52 and never carried out: capture
-- the Win64 fastcall arguments at the TRUE ENTRY POINT of the purchase-commit
-- function, MirrorsEdgeCatalyst.exe+39E1700.
--
-- WHY THIS IS DIFFERENT FROM THE FAILED REGISTER CAPTURES (§51/§52/§54)
-- ---------------------------------------------------------------------
-- Every previous register snapshot was taken mid-function at +39E19AA, which
-- fires constantly for reasons unrelated to purchases -- so any single hit's
-- registers were untrustworthy, exactly as §54 concluded.
--
-- Breaking at the function's first instruction fixes this, because at that
-- exact moment [RSP] still holds the RETURN ADDRESS. That turns "this function
-- fires too often" from a blocker into a filter: every hit is tagged with the
-- call site it came from, so the purchase path (§52 found it returns to
-- +39E24A9) separates itself from the UI-refresh noise automatically. Same
-- trick that made log_tile_pointers.lua work in §50 -- read at the instant of
-- the break, auto-continue, sort it out afterwards.
--
-- SETUP
-- -----
-- 1. Attach CE to MirrorsEdgeCatalyst.exe.
-- 2. Ctrl+G to MirrorsEdgeCatalyst.exe+39E1700, F5 to toggle a breakpoint on
--    that exact instruction (must be the FIRST instruction of the function --
--    if the disassembler shows it mid-body, stop and tell me, the RVA is wrong).
-- 3. Ctrl+Alt+L (Lua Engine), paste this whole file, Execute Script.
--
-- PROTOCOL (do these in order, the baseline matters)
-- --------------------------------------------------
--   a) Open the Progression menu, switch tabs, scroll around for ~10s.
--      DO NOT BUY ANYTHING. This is the noise baseline.
--   b) In the Lua Engine run:   mark("baseline done")
--   c) Buy Double Wallrun (Movement).
--   d) Run:                     mark("bought DoubleWallrun - Movement")
--   e) Buy Climb Efficiency (Movement).
--   f) Run:                     mark("bought ClimbEfficiency - Movement")
--   g) Buy any COMBAT ability.
--   h) Run:                     mark("bought <name> - Combat")
--   i) Run:                     sum()
--   j) Copy the entire output pane and send it to me.
--
-- The Movement-vs-Combat contrast in step (g) is the point: whichever argument
-- differs between those two groups is the category selector, which is what
-- locates Movement's tree without guessing R14 offsets at all.
--
-- KNOBS (edit and re-Execute if needed)
-- -------------------------------------
--   FILTER_RET  -- if the log floods, set to 0x39E24A9 to keep only the known
--                  purchase call site from §52. Leave nil to see everything.
--   MAXDETAIL   -- per-line logging stops after this many hits; counting
--                  continues regardless, so sum() stays accurate.

local MODULE      = "MirrorsEdgeCatalyst.exe"
local TARGET_RVA  = 0x39E1700

FILTER_RET = nil        -- e.g. 0x39E24A9 to keep only §52's purchase call site
MAXDETAIL  = 600

local BASE = getAddress(MODULE)
local BP   = BASE + TARGET_RVA

-- state ---------------------------------------------------------------------
nhits     = 0
ndetail   = 0
callsites = {}   -- [retRvaString] = count
tuples    = {}   -- [retRvaString] = { [argTupleString] = count }
marks     = {}

-- helpers -------------------------------------------------------------------
local function rva(a)
  if a == nil then return "nil" end
  if a >= BASE and a < BASE + 0x10000000 then
    return string.format("+%X", a - BASE)
  end
  return string.format("%X", a)
end

-- first qword at a pointer, rendered as an RVA when it lands in the module.
-- A module-range value here is almost certainly a vtable, which is how we tell
-- a real object apart from an integer that happens to look like an address.
local function pv(a)
  if a == nil or a == 0 then return "-" end
  local q = readQword(a)
  if q == nil then return "?" end
  return rva(q)
end

local function h(v)
  if v == nil then return "nil" end
  return string.format("%X", v)
end

-- user-callable from the Lua Engine ------------------------------------------
function mark(txt)
  table.insert(marks, { n = nhits, t = txt })
  print(string.format(">>> MARK at hit %d: %s", nhits, txt))
end

function clr()
  nhits, ndetail = 0, 0
  callsites, tuples, marks = {}, {}, {}
  print("counters cleared.")
end

function sum()
  print("")
  print("================ SUMMARY ================")
  print(string.format("total hits: %d   (detail lines logged: %d)", nhits, ndetail))

  print("")
  print("-- marks (hit number each mark was placed at) --")
  if #marks == 0 then
    print("  (none -- you didn't call mark(), the log will be much harder to read)")
  end
  for _, m in ipairs(marks) do
    print(string.format("  hit %-6d  %s", m.n, m.t))
  end

  print("")
  print("-- call sites (where this function was called FROM) --")
  local keys = {}
  for k in pairs(callsites) do table.insert(keys, k) end
  table.sort(keys, function(a, b) return callsites[a] > callsites[b] end)
  for _, k in ipairs(keys) do
    print(string.format("  %-14s %d hit(s)", k, callsites[k]))
  end

  print("")
  print("-- distinct argument tuples, grouped by call site --")
  print("   (a call site with ONE tuple across the whole run is shared")
  print("    scaffolding; one that gains a NEW tuple per purchase is the")
  print("    per-ability / per-category argument we're looking for)")
  for _, k in ipairs(keys) do
    print(string.format("  from %s:", k))
    local tk = {}
    for t in pairs(tuples[k]) do table.insert(tk, t) end
    table.sort(tk, function(a, b) return tuples[k][a] > tuples[k][b] end)
    for i, t in ipairs(tk) do
      if i > 25 then
        print(string.format("      ... and %d more distinct tuple(s)", #tk - 25))
        break
      end
      print(string.format("      x%-5d %s", tuples[k][t], t))
    end
  end
  print("=========================================")
end

-- the hook -------------------------------------------------------------------
function debugger_onBreakpoint()
  -- Let any other breakpoint you have set behave normally.
  if RIP ~= BP then return 0 end

  -- At the first instruction of a function, nothing has been pushed yet, so
  -- [RSP] is the return address and the stack args start at [RSP+0x28]
  -- (after the 32-byte shadow space that the caller reserved).
  local ret  = readQword(RSP)
  local rk   = rva(ret)

  if FILTER_RET ~= nil and ret ~= BASE + FILTER_RET then
    return 1
  end

  nhits = nhits + 1
  callsites[rk] = (callsites[rk] or 0) + 1

  local a5 = readQword(RSP + 0x28)
  local a6 = readQword(RSP + 0x30)

  local tup = string.format(
    "RCX=%s[%s] RDX=%s[%s] R8=%s[%s] R9=%s[%s] s5=%s s6=%s",
    h(RCX), pv(RCX), h(RDX), pv(RDX), h(R8), pv(R8), h(R9), pv(R9), h(a5), h(a6))

  tuples[rk] = tuples[rk] or {}
  tuples[rk][tup] = (tuples[rk][tup] or 0) + 1

  if ndetail < MAXDETAIL then
    ndetail = ndetail + 1
    print(string.format("#%-5d ret=%-12s %s", nhits, rk, tup))
  end

  return 1  -- auto-continue
end

print(string.format("armed on %s+%X  (absolute %X, module base %X)",
  MODULE, TARGET_RVA, BP, BASE))
print("Make sure the breakpoint at that address is actually SET (F5 in the disassembler).")
print("Baseline first: open the progression menu and browse ~10s WITHOUT buying,")
print('then run  mark("baseline done")  and start purchasing.')
