-- Dialog box: find its interior, lay out a text and write it as in-game text.
local ctx = ...
local ff1 = ctx.use("ff1")
local tile, writeTile = ff1.tile, ff1.writeTile
local nextAddr, prevAddr = ff1.nextAddr, ff1.prevAddr
local isBorder, encode = ff1.isBorder, ff1.encode

local M = {}

-- Find the usable part of the dialog box around the first captured text tile.
-- The box interior is everything between the border tiles, whatever the
-- tiles currently there. The box can cross into the other nametable (the
-- map scrolls horizontally), so scans follow nextAddr/prevAddr.
-- Returns the address of the first interior tile, the width and the height.
local function dialogArea(addrs)
  local a = addrs[1]
  local row = (a >> 5) & 31

  -- Left edge
  local first = a
  for _ = 1, 31 do
    local p = prevAddr(first)
    if isBorder(tile(p)) then break end
    first = p
  end

  -- Right edge: count interior tiles up to the border
  local width, x = 0, first
  while width < 32 and not isBorder(tile(x)) do
    width = width + 1
    x = nextAddr(x)
  end

  -- Bottom edge
  local lines = 1
  while row + lines <= 29 and not isBorder(tile(a + lines * 32)) do
    lines = lines + 1
  end

  return first, width, lines
end

-- Fit the words of text into `lines` lines of `width` characters. Returns
-- the lines and whether some words could not be placed.
local function layout(text, width, lines)
  local out = {}
  local words = {}
  for w in text:gmatch("%S+") do words[#words + 1] = w end
  local wi = 1
  for li = 1, lines do
    local line = ""
    while wi <= #words do
      local cand = (line == "") and words[wi] or (line .. " " .. words[wi])
      if #cand > width then break end
      line = cand
      wi = wi + 1
    end
    if line == "" and wi <= #words then
      -- a single word wider than the line: cut it
      line = words[wi]:sub(1, width)
      local rest = words[wi]:sub(width + 1)
      if rest == "" then wi = wi + 1 else words[wi] = rest end
    end
    out[li] = line
  end
  return out, wi <= #words
end

-- Write a text over the whole interior of a dialog box, as in-game text.
-- Only the interior of the box is touched, so the map and the border stay intact.
function M.writeBox(first, width, lines, text)
  if width < 1 or lines < 1 then return end
  local out, leftover = layout(text, width, lines)
  if leftover then
    emu.log("LLM answer does not fully fit in dialog box (" .. width .. "x" .. lines .. ")")
  end
  for li = 1, lines do
    local line = out[li] or ""
    local a = first + (li - 1) * 32
    for k = 1, width do
      local c = line:sub(k, k)
      if c == "" then c = " " end
      writeTile(a, encode(c))
      a = nextAddr(a)
    end
  end
end

-- Locate the box around the captured tiles and write the answer over it.
-- Returns the box (first, width, lines), or nil when nothing was written.
function M.writeAnswer(addrs, text)
  if #addrs == 0 then return nil end
  local first, width, lines = dialogArea(addrs)
  emu.log(string.format("BOX first=%04X width=%d lines=%d", first, width, lines))
  if width < 1 or lines < 1 then return nil end
  M.writeBox(first, width, lines, text)
  return first, width, lines
end

return M
