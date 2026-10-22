local FLUSH_FRAMES = 30
local PUNCT = { [0xBF] = ",", [0xC4] = "!" }

local function decode(t)
  if t >= 0x80 and t <= 0x89 then return string.char(0x30 + t - 0x80) end
  if t >= 0x8A and t <= 0xA3 then return string.char(0x41 + t - 0x8A) end
  if t >= 0xA4 and t <= 0xBD then return string.char(0x61 + t - 0xA4) end
  if t == 0xFF then return " " end
  return PUNCT[t]
end

local function snapshot()
  local s = {}
  for a = 0x0000, 0x07FF do s[a] = emu.read(a, emu.memType.nesInternalRam) end
  return s
end

-- état du PPU
local latch, ppuAddr, inc = false, 0, 1
-- capture du texte
local buf, lastAddr, lastFrame = {}, nil, 0
local frame, snaps = 0, {}
local before
-- tri des adresses RAM
local seen, count = {}, 0

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
  if a < 0x2000 or a >= 0x3000 or (a & 0x3FF) >= 0x3C0 then return end  -- hors nametable ou attributs
  local c = decode(val)
  if not c then return end
  if #buf == 0 then before = snaps[1] or snapshot() end
  if lastAddr and a ~= lastAddr + 1 then buf[#buf + 1] = " " end
  buf[#buf + 1] = c
  lastAddr, lastFrame = a, frame
end

local function flush()
  local text = table.concat(buf):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  buf, lastAddr = {}, nil
  if not text:match("%a%a") then return end

  count = count + 1
  local now = snapshot()
  for a = 0x0000, 0x07FF do
    local noise = (a >= 0x0100 and a <= 0x02FF)  -- pile et OAM
    if not noise and now[a] ~= before[a] then seen[a] = (seen[a] or 0) + 1 end
  end
  local common = {}
  for a = 0x0000, 0x07FF do
    if seen[a] == count then common[#common + 1] = string.format("%04X=%02X", a, now[a]) end
  end
  emu.log("TEXTE: " .. text)
  emu.log("COMMUNS (" .. count .. " dialogues): " .. table.concat(common, " "))
end

local function onFrame()
  frame = frame + 1
  if frame % 10 == 0 then
    snaps[#snaps + 1] = snapshot()
    if #snaps > 4 then table.remove(snaps, 1) end
  end
  if #buf > 0 and frame - lastFrame >= FLUSH_FRAMES then flush() end
end

emu.addMemoryCallback(onCtrl,   emu.callbackType.write, 0x2000, 0x2000)
emu.addMemoryCallback(onStatus, emu.callbackType.read,  0x2002, 0x2002)
emu.addMemoryCallback(onAddr,   emu.callbackType.write, 0x2006, 0x2006)
emu.addMemoryCallback(onData,   emu.callbackType.write, 0x2007, 0x2007)
emu.addEventCallback(onFrame, emu.eventType.endFrame)