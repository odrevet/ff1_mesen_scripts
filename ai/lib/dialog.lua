-- Dialog box: find its interior, lay out a text and write it as in-game text.
local ctx = ...
local ff1 = ctx.use("ff1")
local tile, writeTile = ff1.tile, ff1.writeTile
local nextAddr, prevAddr = ff1.nextAddr, ff1.prevAddr
local isBorder, encode = ff1.isBorder, ff1.encode

local M = {}

local NT_ROWS = 30

-- Address of the tile one row below / above, wrapping inside the nametable
-- (the nametable has 30 rows, the map scrolls vertically so a box can
-- cross from row 29 back to row 0).
local function rowDown(a)
  if ((a >> 5) & 31) >= NT_ROWS - 1 then return a - (NT_ROWS - 1) * 32 end
  return a + 32
end

local function rowUp(a)
  if ((a >> 5) & 31) == 0 then return a + (NT_ROWS - 1) * 32 end
  return a - 32
end

-- Find the usable part of the dialog box around the first captured text tile.
-- The box interior is everything between the border tiles, whatever the
-- tiles currently there. Horizontal scans follow nextAddr/prevAddr, vertical
-- scans follow rowUp/rowDown. Both wrap around the nametable.
-- Returns the address of the first interior tile (top left), the width
-- and the height.
local function dialogArea(addrs)
  local a = addrs[1]

  -- Left edge (on the row of the captured tile)
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

  -- Top edge: go up until the tile above is a border
  local up, p = 0, a
  while up < NT_ROWS - 1 do
    local q = rowUp(p)
    if isBorder(tile(q)) then break end
    p = q
    up = up + 1
  end

  -- Bottom edge: go down until the tile below is a border
  local down
  down, p = 0, a
  while up + down < NT_ROWS - 1 do
    local q = rowDown(p)
    if isBorder(tile(q)) then break end
    p = q
    down = down + 1
  end

  for _ = 1, up do first = rowUp(first) end
  return first, width, up + down + 1
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
  local rowStart = first
  for li = 1, lines do
    local line = out[li] or ""
    local a = rowStart
    for k = 1, width do
      local c = line:sub(k, k)
      if c == "" then c = " " end
      writeTile(a, encode(c))
      a = nextAddr(a)
    end
    rowStart = rowDown(rowStart)
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