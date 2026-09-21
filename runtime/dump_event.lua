-- dump_event.lua   (§60: capture the exact event that makes a flag-check entity evaluate)
--
-- §60 (capture_evaluate.lua) established, for Unlocks_MoveEnemyBack:
--     +31250EA  call [r14+08]  ->  +33604F0 (a REAL function: it is a call target)
--        RCX = sender   (class vtable +1C3FCB0 -- same class +3354280 runs on)
--        RDX = event    (stack object, vtable +1A5BDB8)
--        R8  = receiver = the flag-check entity (vtable +1C7B168)
--   and the entity is still alive after the respawn.
--
-- To re-trigger the check without a death we need to reproduce that call, so
-- this captures -- READ-ONLY -- everything needed to do it:
--   1. disassembly of the first instructions of +33604F0 (static; printed at load)
--   2. the EVENT object's bytes, copied at the instant of the call (it lives on
--      the stack, so it must be copied before the call returns)
--   3. the SENDER's header and whether it is still alive afterwards
--   4. the receiver ENTITY's vtable, so we can see its event handler slot
--
-- Why two breakpoints: the entity only caches its flag pointer at [+0x80]
-- DURING the evaluation, so at +33604F0 we can't yet tell which flag it is for.
-- We snapshot every call aimed at a +1C7B168 entity, then at +3A77E14 (after
-- the flag is known) we print the snapshot that belongs to Switch Place.
--
-- The snapshot is also saved in globals (EVT, EVT_BYTES) for the next step.
--
-- SETUP
--   1. F5 on BOTH:  MirrorsEdgeCatalyst.exe+33604F0   and   +3A77E14
--   2. Clear output, paste, Execute.  (disassembly prints immediately)
--   3. Die once.
--   4. After respawn:  alive()
--   5. F5 both off, send everything.

local MODULE = "MirrorsEdgeCatalyst.exe"
local BASE   = getAddress(MODULE)
local BP_EVT   = BASE + 0x33604F0
local BP_CHECK = BASE + 0x3A77E14
local ENT_VT   = BASE + 0x1C7B168

TARGET_HASH = 0x67800619     -- Unlocks_MoveEnemyBack
EVT_SIZE    = 0x60           -- bytes of the event object to copy
VT_SLOTS    = 24             -- entity vtable entries to list

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

local function hexdump(bytes, base_label)
  for row = 0, math.floor((#bytes - 1) / 16) do
    local s, q = "", ""
    for c = 0, 15 do
      local b = bytes[row * 16 + c + 1]
      if b then s = s .. string.format("%02X ", b) end
    end
    print(string.format("     %s+%02X  %s", base_label, row * 16, s))
  end
end

-- ---------------------------------------------------------------- disassembly
print("=== +33604F0, first 40 instructions (static) ===")
local a = BP_EVT
for i = 1, 40 do
  print("   " .. rva(a) .. "   " .. disassemble(a))
  local sz = getInstructionSize(a)
  if sz == nil or sz == 0 then break end
  a = a + sz
end
print("")

-- ---------------------------------------------------------------- flag index
ptrToHash = {}
local tbl = readQword(BASE + 0x257C9D8)
local nb  = u32(tbl + 0x28)
local bk  = readQword(tbl + 0x20)
for i = 0, nb - 1 do
  local node = readQword(bk + i * 8)
  local g = 0
  while node ~= nil and node ~= 0 and g < 2000 do
    local p = readQword(node + 0x10)
    if p then ptrToHash[p] = u32(node) end
    node = readQword(node + 0x28)
    g = g + 1
  end
end

-- ---------------------------------------------------------------- capture
pending   = {}   -- [entity] = snapshot taken at +33604F0
EVT       = nil  -- the Switch Place snapshot, once found
EVT_BYTES = nil

function debugger_onBreakpoint()
  if RIP == BP_EVT then
    if R8 ~= nil and R8 ~= 0 and readQword(R8) == ENT_VT then
      pending[R8] = {
        sender = RCX, event = RDX, entity = R8,
        senderVt = readQword(RCX), eventVt = readQword(RDX),
        bytes = readBytes(RDX, EVT_SIZE, true),
        senderHdr = readBytes(RCX, 0x40, true),
        ret = readQword(RSP),
      }
    end
    return 1
  end

  if RIP == BP_CHECK then
    if EVT ~= nil then return 1 end
    local ent = RBX
    local h = ptrToHash[readQword(ent + 0x80) or 0]
    if h == TARGET_HASH then
      local s = pending[ent]
      if s == nil then
        print(string.format("!! %08X checked by %X but no +33604F0 call was recorded for it", h, ent))
        return 1
      end
      EVT, EVT_BYTES = s, s.bytes
      print(string.format("=== captured the event for %08X (Switch Place) ===", h))
      print(string.format("   entity  %X   vtable %s", s.entity, rva(readQword(s.entity))))
      print(string.format("   sender  %X   vtable %s", s.sender, rva(s.senderVt)))
      print(string.format("   event   %X   vtable %s   (stack object; bytes copied below)", s.event, rva(s.eventVt)))
      print(string.format("   +33604F0 was called from %s", rva(s.ret)))
      print(string.format("   value the entity read: %d", RAX & 0xFFFFFFFF))
      print("")
      print("   event object bytes:")
      hexdump(s.bytes, "evt")
      print("   event object qwords that look like pointers:")
      for off = 0, EVT_SIZE - 8, 8 do
        local q = 0
        for k = 7, 0, -1 do q = q * 256 + (s.bytes[off + k + 1] or 0) end
        if q >= BASE and q < BASE + 0x10000000 then
          print(string.format("     evt+%02X = %s (module)", off, rva(q)))
        elseif q > 0x10000 and q < 0x800000000000 then
          print(string.format("     evt+%02X = %X", off, q))
        end
      end
      print("")
      print("   sender header:")
      hexdump(s.senderHdr, "snd")
      print("")
      print("   entity vtable:")
      local vtp = readQword(s.entity)
      for i = 0, VT_SLOTS - 1 do
        print(string.format("     slot %2d  (+%03X)  %s", i, i * 8, rva(readQword(vtp + i * 8))))
      end
      print("")
    end
    return 1
  end

  return 0
end

function alive()
  if EVT == nil then print("nothing captured -- did both breakpoints fire during the death?") return end
  print(string.format("entity %X: vtable %s  (expect +1C7B168)", EVT.entity, rva(readQword(EVT.entity))))
  print(string.format("sender %X: vtable %s  (was %s)", EVT.sender, rva(readQword(EVT.sender)), rva(EVT.senderVt)))
end

print("armed on +33604F0 and +3A77E14. Die once, then run  alive()")
