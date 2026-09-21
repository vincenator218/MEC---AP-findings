-- Auto-logs every hit of the existing breakpoint at MirrorsEdgeCatalyst.exe+3A1BF63
-- (mov eax,[rcx+10] -- the nameHash read inside the tile stat-formatter).
--
-- Instead of relying on manual Step Into (error-prone -- RCX gets clobbered by
-- the very next instruction, lea rcx,[rbx+38]), this reads RCX and computes
-- nameHash = [RCX+0x10] directly via readInteger at the exact moment the
-- breakpoint fires, before anything has a chance to overwrite it. Then it
-- tries to auto-continue so you don't have to click Run for every single tile.
--
-- Requires: the breakpoint at MirrorsEdgeCatalyst.exe+3A1BF63 already set
-- (via Toggle Breakpoint in the disassembler, as you've been doing).
--
-- Usage: paste into the Lua Engine, Execute Script, then in-game open/close
-- the progression menu (or switch category tabs) to make the tile builder
-- run and fire this breakpoint repeatedly. Watch the Lua Engine's output
-- pane fill up with "hit #N" lines. If the game freezes after the first hit
-- instead of continuing automatically, just click "Run" once in the Memory
-- Viewer -- the script will still correctly log each hit either way, it just
-- won't be hands-free.
--
-- When done (or after ~15-20 hits), copy the full output text and send it
-- back -- no need to identify anything yourself, hash resolution + save-file
-- ownership cross-check happens on the other end.

local hits = {}

function debugger_onBreakpoint()
  local rcx = RCX
  local hash = readInteger(rcx + 0x10)
  if hash ~= nil then
    if hash < 0 then hash = hash + 0x100000000 end
    table.insert(hits, {ptr = rcx, hash = hash})
    print(string.format("hit #%d: RCX=%X nameHash=%X", #hits, rcx, hash))
  else
    print(string.format("hit #%d: RCX=%X (nameHash unreadable)", #hits + 1, rcx))
  end
  return 1 -- ask CE to auto-continue; if it doesn't, just click Run manually
end

print("Logger armed on MirrorsEdgeCatalyst.exe+3A1BF63.")
print("Now open/close the progression menu in-game (or switch tabs) to trigger hits.")
