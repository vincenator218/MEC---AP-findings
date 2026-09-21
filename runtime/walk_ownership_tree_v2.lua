-- v2: exhaustive DFS over the ownership tree, sidestepping the left/right
-- ordering confusion found in v1 (that run showed keys increasing while
-- descending "left", meaning the field roles are flipped from a normal
-- BST, or the comparator is reversed -- doesn't matter here, since this
-- version just visits every reachable node via both child pointers and
-- checks membership directly, with a visited-set to guard against any
-- accidental cycle).
--
-- Confirmed this session: R14 = 0x2BBC3160 (module MirrorsEdgeCatalyst.exe,
-- breakpoint +0x39E19AA). The tree's embedded header is at R14+0x48
-- (0x2BBC31A8): header.left=min node, header.right=max node,
-- header.parent=TRUE ROOT (0x25AA0780). Node layout: +0x00/+0x08 = the
-- two children (order/meaning TBD, doesn't matter for this walk),
-- +0x10 = parent, +0x18 = color byte, +0x20 = key.
--
-- Run with the game attached, still paused at the +0x39E19AA breakpoint:
-- Table -> Show Cheat Engine Lua Engine (Ctrl+Alt+L), paste, Execute Script.

local TARGET = 0x2A1D8848  -- update per-session: current RSI/RDX at the breakpoint hit
local ROOT = 0x25AA0780     -- update per-session: R14+0x58's value (the real root, confirmed this session)

local function hex(v)
  if v == nil then return "nil" end
  return string.format("%X", v)
end

local visited = {}
local allKeys = {}
local foundAt = nil

local function dfs(addr, depth)
  if addr == nil or addr == 0 then return end
  if visited[addr] then
    print(string.format("  !! revisited %X at depth %d -- CYCLE detected, stopping this branch", addr, depth))
    return
  end
  if depth > 200 then
    print(string.format("  !! depth limit at %X -- stopping this branch", addr))
    return
  end
  visited[addr] = true

  local key = readQword(addr + 0x20)
  if key == nil then
    print(string.format("  !! unreadable node at %X (depth %d)", addr, depth))
    return
  end
  table.insert(allKeys, key)
  if key == TARGET then
    foundAt = addr
    print(string.format("  *** FOUND target %X at node %X (depth %d) ***", TARGET, addr, depth))
  end

  local c0 = readQword(addr + 0x00)
  local c1 = readQword(addr + 0x08)
  dfs(c0, depth + 1)
  dfs(c1, depth + 1)
end

print(string.format("=== Exhaustive walk of tree rooted at %X, target %X ===", ROOT, TARGET))
dfs(ROOT, 0)

print(string.format("Visited %d node(s) total.", #allKeys))
table.sort(allKeys)
local keyStrs = {}
for _, k in ipairs(allKeys) do
  table.insert(keyStrs, hex(k))
end
print("All keys found (sorted): " .. table.concat(keyStrs, ", "))

if foundAt then
  print(string.format("RESULT: target %X IS present, at node %X", TARGET, foundAt))
else
  print(string.format("RESULT: target %X was NOT found among the %d node(s) visited.", TARGET, #allKeys))
end

print("Done.")
