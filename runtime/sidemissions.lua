-- sidemissions.lua   (§74: can a side mission be unlocked LIVE?)
--
-- §25: SilverCompleted_<Mission> = 1 is what puts a side mission in the
-- Missions -> Side Missions replay list (proven with a closed-game save edit).
-- This tests the same flag written LIVE into the table (§56). Table write only;
-- no game-function calls (§73: calls on world objects can crash).
--
-- sm()                 list the 11 side missions: SilverCompleted / Available / CompletedTime
-- smset(i, v)          write SilverCompleted_<mission i> = v   (prints old -> new)
-- smrestore()          put every SilverCompleted_ back to the value it had at load
--
-- Before closing the game or leaving a test running: smrestore(), then sm() to confirm.

local MISSIONS = {
  "An Ear to the Ground", "Birdman's Delivery", "Break And Entry", "Caught in the Web",
  "Complete Coverage", "Drone Works", "Exit Strategy", "Finger on the Pulse",
  "The Meta Grid", "Top of the World", "Two Pigeons With One Stone",
}

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

SM_ORIGINAL = SM_ORIGINAL or {}
for i, m in ipairs(MISSIONS) do
  if SM_ORIGINAL[i] == nil then SM_ORIGINAL[i] = val("SilverCompleted_" .. m) end
end

function sm()
  print(" #  Silver  Avail  CompletedTime  mission")
  for i, m in ipairs(MISSIONS) do
    print(string.format("%2d  %-6s  %-5s  %-13s  %s", i, tostring(val("SilverCompleted_" .. m)),
      tostring(val(m .. "_Available")), tostring(val(m .. "_CompletedTime")), m))
  end
end

function smset(i, v)
  local name = "SilverCompleted_" .. MISSIONS[i]
  local h = djb2a(name)
  local n = node(h)
  if not n then print(string.format("%s (%08X): not in table", name, h)) return end
  print(string.format("%s (%08X): %d -> %d", name, h, readInteger(n + 0x18), v))
  writeInteger(n + 0x18, v)
end

function smrestore()
  for i, m in ipairs(MISSIONS) do
    local n = node(djb2a("SilverCompleted_" .. m))
    if n and SM_ORIGINAL[i] ~= nil and readInteger(n + 0x18) ~= SM_ORIGINAL[i] then
      print(string.format("restore %s: %d -> %d", m, readInteger(n + 0x18), SM_ORIGINAL[i]))
      writeInteger(n + 0x18, SM_ORIGINAL[i])
    end
  end
  print("restored (run sm() to confirm)")
end

sm()
print("sm() / smset(i, v) / smrestore()")
