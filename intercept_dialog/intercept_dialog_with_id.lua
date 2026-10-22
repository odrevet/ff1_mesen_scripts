local FLUSH_FRAMES = 30
local PUNCT = { [0xBF] = ",", [0xC4] = "!" }
local SPRITE_ROUTINE = 0xE301
local PLAYER_FROM = 0xE414
local MAP_ID = 0x48

local function decode(t)
  if t >= 0x80 and t <= 0x89 then return string.char(0x30 + t - 0x80) end
  if t >= 0x8A and t <= 0xA3 then return string.char(0x41 + t - 0x8A) end
  if t >= 0xA4 and t <= 0xBD then return string.char(0x61 + t - 0xA4) end
  if t == 0xFF then return " " end
  return PUNCT[t]
end

local function nextAddr(a)
  if (a & 31) == 31 then return (a ~ 0x400) & ~0x1F end
  return a + 1
end

local function rd(a) return emu.read(a, emu.memType.nesMemory) end

-- etat
local latch, ppuAddr, inc = false, 0, 1
local buf, lastAddr, lastFrame, frame = {}, nil, 0, 0
local cur, prev, curFrame = {}, {}, -1
local startList, startMap, startAux, startPX, startPY

local function onSprite()
  if frame ~= curFrame then prev, cur, curFrame = cur, {}, frame end
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

local function findTalker(list)
  local player
  for _, s in ipairs(list) do
    if s.from == PLAYER_FROM then player = s; break end
  end
  if not player then return nil, "joueur introuvable" end
  local best, bestD
  for _, s in ipairs(list) do
    if s.from ~= PLAYER_FROM then
      local d = math.abs(s.x - player.x) + math.abs(s.y - player.y)
      if not bestD or d < bestD then best, bestD = s, d end
    end
  end
  if not best then return nil, "aucun PNJ" end
  return best, best.x - player.x, best.y - player.y
end

local function onCtrl(addr, val) inc = ((val & 4) ~= 0) and 32 or 1 end
local function onStatus() latch = false end

local function onAddr(addr, val)
  if not latch then ppuAddr = (val & 0x3F) << 8
  else ppuAddr = (ppuAddr & 0xFF00) | val end
  latch = not latch
end

local function onData(addr, val)
  local a = ppuAddr
  ppuAddr = (ppuAddr + inc) & 0x3FFF
  if a < 0x2000 or a >= 0x3000 or (a & 0x3FF) >= 0x3C0 then return end
  local c = decode(val)
  if not c then return end
  if #buf == 0 then
    startList = copyList(#prev > 0 and prev or cur)
    startMap, startAux = rd(MAP_ID), rd(MAP_ID + 1)
    startPX, startPY = rd(0x68), rd(0x69)
  end
  if lastAddr and a ~= nextAddr(lastAddr) then buf[#buf + 1] = " " end
  buf[#buf + 1] = c
  lastAddr, lastFrame = a, frame
end

local function flush()
  local text = table.concat(buf):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  buf, lastAddr = {}, nil
  if not text:match("%l%l%l") then return end   -- ignore le chargement de carte
  emu.log("TEXT: " .. text)
  local t, dx, dy = findTalker(startList or {})
  if not t then
    emu.log(string.format("NPC: ? (%s) map=%02X", tostring(dx), startMap))
    return
  end
  local nx = (startPX + ((dx + 8) // 16)) & 0x3F
  local ny = (startPY + ((dy + 8) // 16)) & 0x3F
  emu.log(string.format("NPC: map=%02X off=%02X tile=(%02X,%02X) joueur=(%02X,%02X) 0049=%02X",
    startMap, t.off, nx, ny, startPX, startPY, startAux))
  emu.log(string.format("KEY: %02X:%02X", startMap, t.off))
end

local function onFrame()
  frame = frame + 1
  if #buf > 0 and frame - lastFrame >= FLUSH_FRAMES then flush() end
end

emu.addMemoryCallback(onCtrl,   emu.callbackType.write, 0x2000, 0x2000)
emu.addMemoryCallback(onStatus, emu.callbackType.read,  0x2002, 0x2002)
emu.addMemoryCallback(onAddr,   emu.callbackType.write, 0x2006, 0x2006)
emu.addMemoryCallback(onData,   emu.callbackType.write, 0x2007, 0x2007)
emu.addMemoryCallback(onSprite, emu.callbackType.exec,  SPRITE_ROUTINE, SPRITE_ROUTINE)
emu.addEventCallback(onFrame, emu.eventType.endFrame)