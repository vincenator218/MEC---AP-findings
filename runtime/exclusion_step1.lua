-- exclusion_step1.lua -- STEP 1: does the SDK match this build?
--
-- READ ONLY. Writes nothing, calls nothing. Safe to run any time the game is loaded.
--
-- Goal: confirm that the addresses in ME-AP\SDK\ are valid for the running exe,
-- by reading the type-info objects for the movement exclusion classes and trying
-- to print their class names out of memory.
--
-- Run:  paste into Cheat Engine's Lua window (Table > Show Cheat Table Lua Script,
--       or Ctrl+Alt+L), attach to MirrorsEdgeCatalyst.exe first, then Execute.
--
-- Then send me everything the output box prints.

local BASE = getAddress("MirrorsEdgeCatalyst.exe")

local function hx(v) return string.format("%X", v or 0) end

local function rq(a)
  local ok, v = pcall(readQword, a)
  if ok and v and v ~= 0 then return v end
  return nil
end

-- read a plausible C string at a; returns nil unless it looks like an identifier
local function name_at(a)
  if not a then return nil end
  local ok, s = pcall(readString, a, 96, false)
  if not ok or not s or #s < 3 then return nil end
  if not s:match("^[%w_:<>%s%./]+$") then return nil end
  return s
end

print("=== exclusion_step1 ===")
print("module base = " .. hx(BASE))

---------------------------------------------------------------------------
-- 1. sanity: is this the build our own research was done on?
--    the progression flag table from FINDINGS (tbl = [BASE+0x257C9D8])
---------------------------------------------------------------------------
local tbl = rq(BASE + 0x257C9D8)
if tbl then
  local buckets = rq(tbl + 0x20)
  local nbuck = nil
  local ok, v = pcall(readInteger, tbl + 0x28)
  if ok then nbuck = v end
  print(string.format("flag table   : tbl=%s buckets=%s nbuck=%s",
        hx(tbl), hx(buckets), tostring(nbuck)))
  if nbuck and nbuck > 16 and nbuck < 100000 then
    print("  -> plausible. same build as FINDINGS, game is loaded.")
  else
    print("  -> NOT plausible. either not loaded yet, or a different build.")
  end
else
  print("flag table   : null. load a save first, then re-run.")
end

---------------------------------------------------------------------------
-- 2. the SDK's type-info addresses for the classes we care about
---------------------------------------------------------------------------
local targets = {
  { "PamMovementExclusionVolume",          0x2878c60, 0x2878c80 },
  { "PamMovementExclusionEntityData",      0x2878c00, 0x2878c20 },
  { "PamFindableMovementVolumeEntityData", 0x2884da0, 0x2884dc0 },
  { "PamClientMovementExclusionEntity",    0x285ecf0, nil       },
  -- a control: a class we already know is real and loaded
  { "PamPlayerTagsSettings",               0x2878300, 0x257e598 },
}

for _, t in ipairs(targets) do
  local label, tioff, instoff = t[1], t[2], t[3]
  local ti = BASE + tioff
  print("")
  print("--- " .. label)
  print("  typeinfo addr = " .. hx(ti))

  -- dump the first 0x30 bytes of the type-info object
  local ok, bytes = pcall(readBytes, ti, 0x30, true)
  if not ok or not bytes then
    print("  UNREADABLE -- this address is not mapped. SDK likely built from another exe.")
  else
    local line = {}
    for i = 1, #bytes do line[#line+1] = string.format("%02X", bytes[i]) end
    print("  +00: " .. table.concat(line, " ", 1, 16))
    print("  +10: " .. table.concat(line, " ", 17, 32))
    print("  +20: " .. table.concat(line, " ", 33, 48))

    -- Frostbite type info usually reaches a name string within a pointer or two.
    -- Try the object's own pointers, and one level down, and print anything that
    -- looks like a class name.
    local found = {}
    for off = 0, 0x28, 8 do
      local p = rq(ti + off)
      if p then
        local n = name_at(p)
        if n then found[#found+1] = string.format("[+%02X] -> %q", off, n) end
        for off2 = 0, 0x18, 8 do
          local p2 = rq(p + off2)
          local n2 = name_at(p2)
          if n2 then
            found[#found+1] = string.format("[+%02X][+%02X] -> %q", off, off2, n2)
          end
        end
      end
    end
    if #found == 0 then
      print("  no name string found near the type info")
    else
      for _, f in ipairs(found) do print("  name? " .. f) end
    end
  end

  -- the "GetInstance" pointer the SDK gives, if any
  if instoff then
    local inst = rq(BASE + instoff)
    print(string.format("  instance ptr [%s] = %s", hx(BASE + instoff),
          inst and hx(inst) or "null"))
    if inst then
      local ok2, b2 = pcall(readBytes, inst, 0x10, true)
      if ok2 and b2 then
        local l2 = {}
        for i = 1, #b2 do l2[#l2+1] = string.format("%02X", b2[i]) end
        print("    first 16 bytes: " .. table.concat(l2, " "))
      else
        print("    (unreadable)")
      end
    end
  end
end

print("")
print("=== done. nothing was written. ===")
