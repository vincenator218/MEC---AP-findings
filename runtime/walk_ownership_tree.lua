-- Walks the two candidate red-black trees found at R14+0x48 and R14+0x58
-- (R14 = 0x2BBC3160 this session, module MirrorsEdgeCatalyst.exe) looking
-- for a node keyed by TARGET (the RSI/RDX value captured at the
-- +0x39E19AA breakpoint -- the suspected live PamProgressionFlag pointer
-- for the just-purchased ability, "Fiber Weave" this session).
--
-- Node layout assumed (confirmed partially via manual dump):
--   +0x00 left child (qword)
--   +0x08 right child (qword)
--   +0x10 parent (qword)
--   +0x18 color (byte, 0/1)
--   +0x20 key (qword)
--
-- Run with the game attached: Table -> Show Cheat Engine Lua Engine
-- (Ctrl+Alt+L), paste this whole script, Execute Script. Read results in
-- the Lua Engine's output/console pane.

local TARGET = 0x2A1D8848  -- update this per-session: current RSI/RDX value at the breakpoint hit

local function hex(v)
  if v == nil then return "nil" end
  return string.format("%X", v)
end

local function dumpNode(addr, label)
  if addr == nil or addr == 0 then
    print(string.format("  %s: NULL", label))
    return
  end
  local left = readQword(addr + 0x00)
  local right = readQword(addr + 0x08)
  local parent = readQword(addr + 0x10)
  local color = readInteger(addr + 0x18) -- reads 4 bytes but low byte is what matters
  local key = readQword(addr + 0x20)
  print(string.format("  %s @ %X: left=%s right=%s parent=%s color=%s key=%s",
    label, addr, hex(left), hex(right), hex(parent), tostring(color), hex(key)))
end

local function walk(nodeAddr, target, path, depth)
  if depth > 40 then
    print("  !! depth limit hit, probably a bad pointer chain -- aborting this branch")
    return false
  end
  if nodeAddr == nil or nodeAddr == 0 then
    print(string.format("  dead end (NULL) at path '%s' -- target NOT found on this path", path))
    return false
  end
  local key = readQword(nodeAddr + 0x20)
  if key == nil then
    print(string.format("  !! unreadable memory at %X (path '%s') -- aborting this branch", nodeAddr, path))
    return false
  end
  print(string.format("  node %X  key=%X  (path '%s')", nodeAddr, key, path))
  if key == target then
    print(string.format("  *** FOUND target %X at node %X (path '%s') ***", target, nodeAddr, path))
    return true
  elseif target < key then
    local left = readQword(nodeAddr + 0x00)
    return walk(left, target, path .. "L", depth + 1)
  else
    local right = readQword(nodeAddr + 0x08)
    return walk(right, target, path .. "R", depth + 1)
  end
end

print(string.format("=== Searching for TARGET %X ===", TARGET))

local candidates = {
  { name = "tree #1 (R14+0x48)", root = 0x25AD36C0 },
  { name = "tree #2 (R14+0x58)", root = 0x25AA0780 },
}

for _, c in ipairs(candidates) do
  print(string.format("--- %s, starting node %X ---", c.name, c.root))
  dumpNode(c.root, "start node")
  local parent = readQword(c.root + 0x10)
  if parent ~= nil and parent ~= 0 and parent ~= c.root then
    print("  (start node has a non-null parent -- could be a sentinel/header; also dumping it)")
    dumpNode(parent, "start node's parent")
  end
  print("  walking down from the start node:")
  local found = walk(c.root, TARGET, "", 0)
  if parent ~= nil and parent ~= 0 and parent ~= c.root and not found then
    print("  walking down from the parent instead (in case start node was a header, not the root):")
    walk(parent, TARGET, "", 0)
  end
end

print("Done.")
