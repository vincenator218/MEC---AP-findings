-- capture_evaluate.lua   (§60: find the flag-check entity's real evaluate function)
--
-- §59 showed each ability is enforced by ONE entity of class +1C7B168 that
-- checks its flag once, at respawn. To apply a grant without dying we need to
-- make that entity check again, which needs:
--   (a) the entity's REAL evaluate function -- not a CC-padding guess
--       (+3A77DB3 was a guess and never executed)
--   (b) the arguments it is called with
--   (c) whether the entity is still alive after the respawn
--
-- The respawn chain reaches the check through an indirect call in +31250A0:
--
--     +31250E0  mov rcx,[r14]
--     +31250E3  lea r8,[rdi-08]
--     +31250E7  mov rdx,rax
--     +31250EA  call qword ptr [r14+08]     <-- target = the evaluate function
--
-- So this script sets TWO breakpoints:
--   +31250EA  records the call about to happen: target=[r14+08], RCX, RDX, R8
--   +3A77E14  (inside the check) reads which flag the entity asked about; when
--             it is TARGET_HASH, prints the most recent +31250EA record, so we
--             see exactly which call led to our flag's check and how the
--             arguments relate to the entity (RBX).
--
-- Read-only. Nothing is written or called.
--
-- SETUP
--   1. F5 breakpoints on BOTH:
--        MirrorsEdgeCatalyst.exe+31250EA
--        MirrorsEdgeCatalyst.exe+3A77E14
--   2. Clear output, paste this, Execute.
--   3. Die once (no idle baseline needed this time).
--   4. After respawning, run:   alive()
--      It re-reads the captured entity to see if it still exists.
--   5. F5 both breakpoints off, send the output.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)
local BP_CALL  = BASE + 0x31250EA
local BP_CHECK = BASE + 0x3A77E14

TARGET_HASH = 0x67800619     -- Unlocks_MoveEnemyBack (Switch Place)

local function u32(a)
  local v = readInteger(a)
  if v == nil then return nil end
  if v < 0 then v = v + 0x100000000 end
  return v
end

local function rva(a)
  if a == nil then return "nil" end
  if a >= BASE and a < BASE + 0x10000000 then
    return string.format("+%X", a - BASE)
  end
  return string.format("%X", a)
end

local function vt(a)
  if a == nil or a == 0 then return "-" end
  local q = readQword(a)
  if q == nil then return "?" end
  return rva(q)
end

-- node+0x10 -> hash (the field §59 showed [entity+0x80] points at)
ptrToHash = {}
local n = 0
local tbl = readQword(BASE + 0x257C9D8)
if tbl ~= nil and tbl ~= 0 then
  local nbuck   = u32(tbl + 0x28)
  local buckets = readQword(tbl + 0x20)
  for i = 0, nbuck - 1 do
    local node = readQword(buckets + i * 8)
    local guard = 0
    while node ~= nil and node ~= 0 and guard < 2000 do
      local p = readQword(node + 0x10)
      if p ~= nil and p ~= 0 then ptrToHash[p] = u32(node); n = n + 1 end
      node = readQword(node + 0x28)
      guard = guard + 1
    end
  end
end

lastCall   = nil   -- most recent +31250EA snapshot
targets    = {}    -- [target rva] = count, across ALL calls through [r14+08]
captured   = nil   -- snapshot for TARGET_HASH
ncalls, nchecks = 0, 0

function alive()
  if captured == nil then print("nothing captured yet -- did you die with both breakpoints set?") return end
  local e = captured.ent
  print(string.format("captured entity %X: vtable now %s (was %s), [+0x80] now %X (was %X)",
    e, vt(e), captured.vt, readQword(e + 0x80) or 0, captured.def))
  if vt(e) == captured.vt and readQword(e + 0x80) == captured.def then
    print("  -> entity looks ALIVE and unchanged after respawn.")
  else
    print("  -> entity looks GONE or reused (one-shot). Re-evaluation would need a new instance.")
  end
end

function debugger_onBreakpoint()
  if RIP == BP_CALL then
    ncalls = ncalls + 1
    local tgt = readQword(R14 + 0x08)
    lastCall = { tgt = tgt, rcx = RCX, rdx = RDX, r8 = R8, r14 = R14 }
    local k = rva(tgt)
    targets[k] = (targets[k] or 0) + 1
    return 1
  end

  if RIP == BP_CHECK then
    nchecks = nchecks + 1
    local ent = RBX
    local def = readQword(ent + 0x80)
    local h = def and ptrToHash[def] or nil
    if h == TARGET_HASH and captured == nil then
      captured = { ent = ent, def = def, vt = vt(ent) }
      print("")
      print(string.format("=== %08X checked by entity %X (vtable %s), value EAX=%d ===",
        h, ent, captured.vt, RAX & 0xFFFFFFFF))
      if lastCall then
        print(string.format("   last call via +31250EA: target %s", rva(lastCall.tgt)))
        print(string.format("      RCX=%X [%s]  RDX=%X [%s]  R8=%X [%s]  R14=%X",
          lastCall.rcx, vt(lastCall.rcx), lastCall.rdx, vt(lastCall.rdx),
          lastCall.r8, vt(lastCall.r8), lastCall.r14))
        print(string.format("      RCX==entity? %s   RDX==entity? %s   R8+8==entity? %s",
          tostring(lastCall.rcx == ent), tostring(lastCall.rdx == ent),
          tostring(lastCall.r8 + 8 == ent)))
      else
        print("   no +31250EA call recorded before this check -- it came another way.")
      end
      print("")
    end
    return 1
  end

  return 0
end

function sum()
  print(string.format("calls through +31250EA: %d   checks at +3A77E14: %d", ncalls, nchecks))
  print("targets of call [r14+08]:")
  for k, c in pairs(targets) do print(string.format("   %-12s x%d", k, c)) end
end

print(string.format("indexed %d node+10 pointers (expect ~2374)", n))
print(string.format("breakpoints needed: %s and %s", rva(BP_CALL), rva(BP_CHECK)))
print("Die once, then run  alive()  and  sum()")
