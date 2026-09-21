-- Finds the real C++ vtable address for PamClientProgressionFlagEntity and
-- PamServerProgressionFlagEntity by walking MSVC RTTI backwards:
--   TypeDescriptor address (known, from the SDK's GetTypeInfo())
--     <- RTTICompleteObjectLocator.pTypeDescriptor (image-base-relative RVA, offset 0xC)
--        (self-validated via .pSelf at offset 0x14)
--     <- vtable[-1] (plain 8-byte pointer to the RTTICompleteObjectLocator)
--   vtable = (that pointer's address) + 8
--
-- Run with the game attached in Cheat Engine: Table -> Show Cheat Engine Lua Engine
-- (or Ctrl+Alt+L), paste this whole script, Execute Script. Read results in the
-- Lua Engine's output/console pane.

local MODULE_BASE = 0x140000000

local function byteOf(v, shiftBytes)
  return bAnd(bShr(v, shiftBytes * 8), 0xFF)
end

local function dwordPattern(v)
  return string.format("%02X %02X %02X %02X",
    byteOf(v, 0), byteOf(v, 1), byteOf(v, 2), byteOf(v, 3))
end

local function qwordPattern(v)
  local parts = {}
  for i = 0, 7 do
    parts[#parts + 1] = string.format("%02X", byteOf(v, i))
  end
  return table.concat(parts, " ")
end

local targets = {
  { name = "PamClientProgressionFlagEntity", rva = 0x285fe50 },
  { name = "PamServerProgressionFlagEntity", rva = 0x28641a0 },
}

for _, t in ipairs(targets) do
  print(string.format("=== %s (TypeDescriptor RVA %X) ===", t.name, t.rva))

  local pat = dwordPattern(t.rva)
  local hits = AOBScan(pat, "", 1, "4")  -- 4-byte aligned
  local validatedCols = {}

  if hits ~= nil then
    print("  raw TypeDescriptor-RVA hits: " .. hits.Count)
    for i = 0, hits.Count - 1 do
      local hitAddr = tonumber(hits[i], 16)
      local colStart = hitAddr - 0xC
      local pSelfRva = readInteger(colStart + 0x14)
      if pSelfRva ~= nil then
        local computedSelf = MODULE_BASE + pSelfRva
        if computedSelf == colStart then
          table.insert(validatedCols, colStart)
          print(string.format("  validated RTTICompleteObjectLocator at %X", colStart))
        end
      end
    end
    hits.destroy()
  else
    print("  AOBScan returned nil (no hits)")
  end

  if #validatedCols == 0 then
    print("  No validated RTTICompleteObjectLocator found for this class.")
  end

  for _, col in ipairs(validatedCols) do
    local qpat = qwordPattern(col)
    local vhits = AOBScan(qpat, "", 1, "8")  -- 8-byte aligned
    if vhits ~= nil then
      print(string.format("  COL %X -> vtable-pointer-slot hits: %d", col, vhits.Count))
      for j = 0, vhits.Count - 1 do
        local slotAddr = tonumber(vhits[j], 16)
        local vtableAddr = slotAddr + 8
        print(string.format("    ==> candidate vtable address: %X", vtableAddr))
      end
      vhits.destroy()
    else
      print(string.format("  COL %X -> no vtable-pointer-slot hits found", col))
    end
  end
end

print("Done.")
