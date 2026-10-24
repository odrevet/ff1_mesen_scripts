-- NPC detection: record the sprites drawn by the game and find who is talking.
local ctx = ...
local C, state = ctx.C, ctx.state
local rd = ctx.use("ff1").rd

local M = {}

local cur, prev, curFrame = {}, {}, -1

-- Record each sprite drawn by the game routine (position, pointer, caller)
function M.onSprite()
  if state.frame ~= curFrame then prev, cur, curFrame = cur, {}, state.frame end
  local sp = emu.getState()["cpu.sp"]
  local ret = rd(0x100 + ((sp + 1) & 0xFF)) | (rd(0x100 + ((sp + 2) & 0xFF)) << 8)
  cur[#cur + 1] = {
    x = rd(0x40), y = rd(0x41),
    ptr = rd(0x10) | (rd(0x11) << 8),
    off = rd(0x12), from = ret + 1,
  }
end

local function copyList(list)
  local c = {}
  for i, s in ipairs(list) do c[i] = s end
  return c
end

-- Copy of the sprites of the last complete frame (or the current one)
function M.snapshot()
  return copyList(#prev > 0 and prev or cur)
end

-- Find the NPC closest to the player (the one who is talking).
-- Returns the sprite, dx, dy, or nil and a reason.
function M.findTalker(list)
  local player
  for _, s in ipairs(list) do
    if s.from == C.PLAYER_FROM then player = s; break end
  end
  if not player then return nil, "player not found" end
  local best, bestD
  for _, s in ipairs(list) do
    if s.from ~= C.PLAYER_FROM then
      local d = math.abs(s.x - player.x) + math.abs(s.y - player.y)
      if not bestD or d < bestD then best, bestD = s, d end
    end
  end
  if not best then return nil, "no NPC" end
  return best, best.x - player.x, best.y - player.y
end

return M
