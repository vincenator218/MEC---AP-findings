-- log_apply_candidates.lua   (§58: which frame is the ability-rebuild routine?)
--
-- The respawn chain, with function starts taken from the CALL TARGETS in the
-- §58 disassembly (not from the CC-padding guess, which was a few bytes early):
--
--   +337440B --call--> +3354280 --call--> +31250A0 --call [r14+08]--> +3A77DB3
--                                                                      |
--                                                        call +39DA880 (flag value)
--                                                        which contains +39DA8DD
--
-- +3A77DB3 asks ONE item whether it is owned. +31250A0 calls through [r14+08],
-- so it is dispatching over a list -- the shape of "rebuild all abilities".
-- This logs the ENTRY of the three candidates to answer:
--
--   1. WHEN do they fire? Only on respawn, or constantly? A routine that runs
--      every frame is not a rebuild and cannot be triggered on demand.
--   2. WHAT are their arguments? At the entry, RCX is the `this` pointer. If
--      the same object shows up every respawn, the AP client can capture it
--      once and reuse it. The first qword at RCX is the vtable, which
--      identifies the class.
--   3. HOW MANY times per respawn? +3A77DB3 firing ~2374 times would mean it
--      is asked about every flag; firing ~20 times means a short list.
--
-- SETUP
--   1. Ctrl+G to each of these and F5 to set a breakpoint on each:
--        MirrorsEdgeCatalyst.exe+31250A0
--        MirrorsEdgeCatalyst.exe+3354280
--        MirrorsEdgeCatalyst.exe+3A77DB3
--      (If one turns out to fire thousands of times a second and the game
--       becomes unplayable, F5 it off and re-run with just the other two.)
--   2. Paste this, Execute.
--   3. Play ~10s without dying, then:  mark("idle baseline")
--   4. Die / restart from checkpoint.
--   5. After respawning:  mark("after respawn")   then   sum()
--
-- Reading the result: a candidate with ZERO hits before the idle mark and a
-- burst after it is the respawn path. Its RCX is the object the AP client
-- needs. If a candidate fires constantly, it is general scaffolding -- ignore.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)

CAND = {
  [BASE + 0x31250A0] = "+31250A0 (dispatches over a list)",
  [BASE + 0x3354280] = "+3354280 (its caller)",
  [BASE + 0x3A77DB3] = "+3A77DB3 (per-item ownership query)",
}

MAXDETAIL = 80

nhits  = 0
counts = {}    -- [name] = total hits
tuples = {}    -- [name] = { [argString] = count }
marks  = {}
ndetail = 0

local function rva(a)
  if a == nil then return "nil" end
  if a >= BASE and a < BASE + 0x10000000 then
    return string.format("+%X", a - BASE)
  end
  return string.format("%X", a)
end

-- the first qword at a pointer: a module-range value is almost certainly a
-- vtable, which is how we tell a real object from an integer
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

function mark(txt)
  table.insert(marks, { n = nhits, t = txt })
  print(string.format(">>> MARK at hit %d: %s", nhits, txt))
  for name, c in pairs(counts) do
    print(string.format("      %-40s %d hits so far", name, c))
  end
end

function clr()
  nhits, ndetail = 0, 0
  counts, tuples, marks = {}, {}, {}
  print("cleared.")
end

function sum()
  print("")
  print("================ SUMMARY ================")
  print(string.format("total hits across all candidates: %d", nhits))

  print("")
  print("-- marks --")
  for _, m in ipairs(marks) do
    print(string.format("   hit %-6d %s", m.n, m.t))
  end

  print("")
  print("-- hits per candidate --")
  for name, c in pairs(counts) do
    print(string.format("   %-42s %d", name, c))
  end

  print("")
  print("-- distinct argument tuples per candidate --")
  for name, tk in pairs(tuples) do
    print(string.format("   %s:", name))
    local keys = {}
    for k in pairs(tk) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tk[a] > tk[b] end)
    for i, k in ipairs(keys) do
      if i > 12 then
        print(string.format("      ... and %d more distinct tuple(s)", #keys - 12))
        break
      end
      print(string.format("      x%-5d %s", tk[k], k))
    end
  end
  print("=========================================")
end

function debugger_onBreakpoint()
  local name = CAND[RIP]
  if name == nil then return 0 end   -- not ours: let other breakpoints behave normally

  nhits = nhits + 1
  counts[name] = (counts[name] or 0) + 1

  local tup = string.format("RCX=%s[%s] RDX=%s[%s] R8=%s[%s]",
    h(RCX), pv(RCX), h(RDX), pv(RDX), h(R8), pv(R8))

  tuples[name] = tuples[name] or {}
  tuples[name][tup] = (tuples[name][tup] or 0) + 1

  if ndetail < MAXDETAIL then
    ndetail = ndetail + 1
    print(string.format("#%-4d %-42s %s", nhits, name, tup))
  end

  return 1   -- auto-continue
end

print("armed. breakpoints must be SET (F5) on:")
for a, name in pairs(CAND) do
  print(string.format("   %s  ->  %s", rva(a), name))
end
print('Idle ~10s, then mark("idle baseline"), then DIE, then mark("after respawn"), then sum()')
