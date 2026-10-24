-- FF1 text decoding / encoding and low level memory / nametable helpers.
local M = {}

local PUNCT = { [0xBF] = ",", [0xC4] = "!" }

-- FF1 tile ID to character (nil when the tile is not a text character)
function M.decode(t)
  if t >= 0x80 and t <= 0x89 then return string.char(0x30 + t - 0x80) end
  if t >= 0x8A and t <= 0xA3 then return string.char(0x41 + t - 0x8A) end
  if t >= 0xA4 and t <= 0xBD then return string.char(0x61 + t - 0xA4) end
  if t == 0xFF then return " " end
  return PUNCT[t]
end

-- Inverse of decode(): character to FF1 tile ID (unknown characters become a space)
local ENC = { [" "] = 0xFF }
for t, c in pairs(PUNCT) do ENC[c] = t end

function M.encode(c)
  if c == "" then return 0xFF end
  if ENC[c] then return ENC[c] end
  local b = c:byte()
  if b >= 0x30 and b <= 0x39 then return 0x80 + b - 0x30 end
  if b >= 0x41 and b <= 0x5A then return 0x8A + b - 0x41 end
  if b >= 0x61 and b <= 0x7A then return 0xA4 + b - 0x61 end
  return 0xFF
end

-- Next nametable address (wraps within the 32 tile row)
function M.nextAddr(a)
  if (a & 31) == 31 then return (a ~ 0x400) & ~0x1F end
  return a + 1
end

-- Previous nametable address (wraps within the 32 tile row)
function M.prevAddr(a)
  if (a & 31) == 0 then return (a ~ 0x400) | 0x1F end
  return a - 1
end

function M.rd(a) return emu.read(a, emu.memType.nesMemory) end

-- Nametable RAM is what the PPU displays; & 0x7FF handles the 2KB of RAM
function M.tile(a) return emu.read(a & 0x7FF, emu.memType.nesNametableRam) end
function M.writeTile(a, v) emu.write(a & 0x7FF, v, emu.memType.nesNametableRam) end

function M.normalize(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- FF1 dialog box border tiles
function M.isBorder(t) return t >= 0xF7 and t <= 0xFE end

return M
