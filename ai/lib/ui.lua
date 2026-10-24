-- Chat UI: keyboard input, controller blocking and the overlay drawn on screen.
local ctx = ...
local C, state = ctx.C, ctx.state
local ff1 = ctx.use("ff1")
local llm = ctx.use("llm")
local dialog = ctx.use("dialog")

local tile, prevAddr, isBorder = ff1.tile, ff1.prevAddr, ff1.isBorder
local sanitize = llm.sanitize

local M = {}

-- ---------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------
-- Key names must match the strings shown in Mesen's key binding UI. Several
-- names are tried for the keys whose label can differ between platforms.
local function keyDown(names)
  for _, n in ipairs(names) do
    local ok, res = pcall(emu.isKeyPressed, n)
    if ok and res then return true end
  end
  return false
end

local KEYS = {}
local function addKey(id, names) KEYS[#KEYS + 1] = { id = id, names = names, held = false } end
for c = string.byte("A"), string.byte("Z") do
  local l = string.char(c)
  addKey(l, { l })
end
for d = 0, 9 do
  local s = tostring(d)
  addKey(s, { s, "Numpad" .. s })
end
addKey("space", { "Space" })
addKey("comma", { "Comma", "," })
addKey("back", { "Backspace" })
addKey("enter", { "Enter", "Return" })
addKey("escape", { "Escape", "Esc" })
addKey("slash", { "Slash", "/", "Divide" })
local SHIFT = { "Left Shift", "Right Shift", "Shift", "LeftShift", "RightShift" }

-- Keys newly pressed since the previous call, and the shift state
local function pollKeys()
  local pressed = {}
  for _, k in ipairs(KEYS) do
    local down = keyDown(k.names)
    if down and not k.held then pressed[#pressed + 1] = k.id end
    k.held = down
  end
  return pressed, keyDown(SHIFT)
end

-- ---------------------------------------------------------------
-- Chat logic
-- ---------------------------------------------------------------
-- pressA: when the player closes the chat, press A for a few frames so the
-- game dialog box closes too (executed in onInput).
local function closeChat(pressA)
  state.session, state.chat.active, state.chat.input = nil, false, ""
  if pressA then state.pressA = 3 end
end

-- Send the typed message with the whole conversation, show the answer
local function submit()
  local chat = state.chat
  local msg = sanitize(chat.input)
  chat.input = ""
  if msg == "" then return end
  local s = state.session
  s.messages[#s.messages + 1] = { role = "user", content = msg }
  emu.log("PLAYER: " .. msg)
  local reply = llm.chatReply(s.messages)
  if not reply then
    s.messages[#s.messages] = nil
    return
  end
  s.messages[#s.messages + 1] = { role = "assistant", content = reply }
  dialog.writeBox(s.first, s.width, s.lines, reply)
  emu.log("CHAT NPC: " .. reply)
end

local function handleKey(id, shift)
  local chat = state.chat
  if id == "escape" then
    emu.log("CHAT CLOSED")
    closeChat(true)
  elseif id == "enter" then
    if sanitize(chat.input) == "" then
      emu.log("CHAT CLOSED")
      closeChat(true)
    else
      submit()
    end
  elseif id == "back" then
    chat.input = chat.input:sub(1, -2)
  elseif #chat.input < C.MAX_INPUT then
    if id == "space" then
      chat.input = chat.input .. " "
    elseif id == "comma" then
      chat.input = chat.input .. (shift and "?" or ",")
    elseif id == "slash" then
      -- AZERTY: this physical key is "!" (QWERTY: "/", shift gives "?")
      chat.input = chat.input .. (shift and "?" or "!")
    elseif id:match("^%d$") then
      chat.input = chat.input .. ((shift and id == "1") and "!" or id)
    elseif id:match("^%a$") then
      chat.input = chat.input .. (shift and id or id:lower())
    end
  end
end

-- ---------------------------------------------------------------
-- Pixel font (8x8 cells, 6 px wide glyphs, bold strokes like FF1)
-- ---------------------------------------------------------------
local FONT = {
  A = ".####.,##..##,##..##,######,##..##,##..##,##..##",
  B = "#####.,##..##,##..##,#####.,##..##,##..##,#####.",
  C = ".####.,##..##,##....,##....,##....,##..##,.####.",
  D = "####..,##.##.,##..##,##..##,##..##,##.##.,####..",
  E = "######,##....,##....,####..,##....,##....,######",
  F = "######,##....,##....,####..,##....,##....,##....",
  G = ".####.,##..##,##....,##.###,##..##,##..##,.####.",
  H = "##..##,##..##,##..##,######,##..##,##..##,##..##",
  I = "######,..##..,..##..,..##..,..##..,..##..,######",
  J = "..####,...##.,...##.,...##.,##.##.,##.##.,.###..",
  K = "##..##,##.##.,####..,###...,####..,##.##.,##..##",
  L = "##....,##....,##....,##....,##....,##....,######",
  M = "##..##,######,######,##..##,##..##,##..##,##..##",
  N = "##..##,###.##,######,##.###,##..##,##..##,##..##",
  O = ".####.,##..##,##..##,##..##,##..##,##..##,.####.",
  P = "#####.,##..##,##..##,#####.,##....,##....,##....",
  Q = ".####.,##..##,##..##,##..##,##.###,##.##.,.##.##",
  R = "#####.,##..##,##..##,#####.,####..,##.##.,##..##",
  S = ".#####,##....,##....,.####.,....##,....##,#####.",
  T = "######,..##..,..##..,..##..,..##..,..##..,..##..",
  U = "##..##,##..##,##..##,##..##,##..##,##..##,.####.",
  V = "##..##,##..##,##..##,##..##,##..##,.####.,..##..",
  W = "##..##,##..##,##..##,##..##,######,######,##..##",
  X = "##..##,##..##,.####.,..##..,.####.,##..##,##..##",
  Y = "##..##,##..##,.####.,..##..,..##..,..##..,..##..",
  Z = "######,....##,...##.,..##..,.##...,##....,######",

  a = "......,......,.####.,....##,.#####,##..##,.#####",
  b = "##....,##....,#####.,##..##,##..##,##..##,#####.",
  c = "......,......,.####.,##..##,##....,##..##,.####.",
  d = "....##,....##,.#####,##..##,##..##,##..##,.#####",
  e = "......,......,.####.,##..##,######,##....,.####.",
  f = "..###.,.##...,####..,.##...,.##...,.##...,.##...",
  g = "......,......,.#####,##..##,##..##,.#####,....##,.####.",
  h = "##....,##....,#####.,##..##,##..##,##..##,##..##",
  i = "..##..,......,.###..,..##..,..##..,..##..,.####.",
  j = "...##.,......,..###.,...##.,...##.,...##.,##.##.,.###..",
  k = "##....,##....,##..##,##.##.,####..,##.##.,##..##",
  l = ".###..,..##..,..##..,..##..,..##..,..##..,.####.",
  m = "......,......,#####.,##.#.#,##.#.#,##.#.#,##.#.#",
  n = "......,......,#####.,##..##,##..##,##..##,##..##",
  o = "......,......,.####.,##..##,##..##,##..##,.####.",
  p = "......,......,#####.,##..##,##..##,#####.,##....,##....",
  q = "......,......,.#####,##..##,##..##,.#####,....##,....##",
  r = "......,......,##.###,###...,##....,##....,##....",
  s = "......,......,.#####,##....,.####.,....##,#####.",
  t = ".##...,.##...,####..,.##...,.##...,.##.##,..###.",
  u = "......,......,##..##,##..##,##..##,##..##,.#####",
  v = "......,......,##..##,##..##,##..##,.####.,..##..",
  w = "......,......,##..##,##..##,##..##,######,.####.",
  x = "......,......,##..##,.####.,..##..,.####.,##..##",
  y = "......,......,##..##,##..##,##..##,.#####,....##,.####.",
  z = "......,......,######,...##.,..##..,.##...,######",

  ["0"] = ".####.,##..##,##.###,######,###.##,##..##,.####.",
  ["1"] = "..##..,.###..,..##..,..##..,..##..,..##..,######",
  ["2"] = ".####.,##..##,....##,..###.,.##...,##....,######",
  ["3"] = ".####.,##..##,....##,..###.,....##,##..##,.####.",
  ["4"] = "...##.,..###.,.####.,##.##.,######,...##.,...##.",
  ["5"] = "######,##....,#####.,....##,....##,##..##,.####.",
  ["6"] = ".####.,##....,#####.,##..##,##..##,##..##,.####.",
  ["7"] = "######,....##,...##.,..##..,..##..,..##..,..##..",
  ["8"] = ".####.,##..##,##..##,.####.,##..##,##..##,.####.",
  ["9"] = ".####.,##..##,##..##,.#####,....##,....##,.####.",

  ["!"] = "..##..,..##..,..##..,..##..,..##..,......,..##..",
  ["?"] = ".####.,##..##,....##,..###.,..##..,......,..##..",
  [","] = "......,......,......,......,......,..##..,..##..,.##...",
  [">"] = "##....,.##...,..##..,...##.,..##..,.##...,##....",
  ["_"] = "......,......,......,......,......,......,......,######",
}

-- Parse each glyph into a list of horizontal runs {row, start, length}
local GLYPHS = {}
for ch, def in pairs(FONT) do
  local runs, row = {}, 0
  for line in def:gmatch("[^,]+") do
    local x = 1
    while x <= #line do
      if line:sub(x, x) == "#" then
        local e = x
        while e < #line and line:sub(e + 1, e + 1) == "#" do e = e + 1 end
        runs[#runs + 1] = { row, x - 1, e - x + 1 }
        x = e + 1
      else
        x = x + 1
      end
    end
    row = row + 1
  end
  GLYPHS[ch] = runs
end

local function drawText(x, y, text, col)
  for i = 1, #text do
    local runs = GLYPHS[text:sub(i, i)]
    if runs then
      local cx = x + (i - 1) * 8 + 1
      for _, r in ipairs(runs) do
        emu.drawRectangle(cx + r[2], y + r[1], r[3], 1, col, true, 1)
      end
    end
  end
end

-- ---------------------------------------------------------------
-- Overlay
-- ---------------------------------------------------------------
-- Overlay styled like the FF1 dialog window (same margins as the game box:
-- 16 px from the left edge, 224 px wide). Colors are 0xAARRGGBB with an
-- inverted alpha: 0x00 opaque, 0xFF transparent.
local BOX_X, BOX_Y, BOX_W, BOX_H = 16, 184, 224, 32
local COL_BG    = 0x00002A88   -- window blue
local COL_WHITE = 0x00FFFFFF   -- text
local COL_LINE  = 0x00FFFEFF   -- inner frame line
local COL_GRAY  = 0x00666666   -- outer frame line
local COL_BLACK = 0x00000000   -- outline around the window
local ANIM_STEP = 4            -- pixels gained per frame (32 px = 8 frames)

local function fill(x, y, w, h, col)
  emu.drawRectangle(x, y, w, h, col, true, 1)
end

-- Filled rectangle without its 4 corner pixels
local function notched(x, y, w, h, col)
  fill(x + 1, y, w - 2, h, col)
  fill(x, y + 1, w, h - 2, col)
end

-- Double frame with notched corners, like the game window
local function drawFrame(x, y, w, h)
  notched(x - 1, y - 1, w + 2, h + 2, COL_BLACK)  -- outline
  notched(x, y, w, h, COL_GRAY)                   -- outer gray line
  notched(x + 1, y + 1, w - 2, h - 2, COL_LINE)   -- inner white line
  notched(x + 2, y + 2, w - 4, h - 4, COL_BG)     -- blue window
end

local function drawChat()
  if not state.chat.active then return end
  local s = state.session
  if not s then return end
  -- Opening animation: the box grows from top to bottom
  s.animH = math.min(BOX_H, (s.animH or 0) + ANIM_STEP)
  drawFrame(BOX_X, BOX_Y, BOX_W, math.max(s.animH, 6))
  if s.animH < BOX_H then return end
  -- 26 cells fit in the window: 25 characters + cursor
  local shown = state.chat.input
  if #shown > 25 then shown = shown:sub(-25) end
  local cursor = ((state.frame // 20) % 2 == 0) and "_" or " "
  drawText(BOX_X + 8, BOX_Y + 12, shown .. cursor, COL_WHITE)
end

-- ---------------------------------------------------------------
-- Controller blocking and A press
-- ---------------------------------------------------------------
local NONE = { a = false, b = false, select = false, start = false,
               up = false, down = false, left = false, right = false }
local PRESS_A = { a = true, b = false, select = false, start = false,
                  up = false, down = false, left = false, right = false }
-- The setInput signature differs between Mesen versions: try each one
local SET_INPUT = {
  function(t) emu.setInput(0, t) end,
  function(t) emu.setInput(t, 0) end,
  function(t) emu.setInput(t, 0, 0) end,
  function(t) emu.setInput(0, 0, t) end,
}
local setInputIdx, setInputFailed = nil, false

local function send(t)
  if setInputIdx then pcall(SET_INPUT[setInputIdx], t); return end
  if setInputFailed then return end
  for i, f in ipairs(SET_INPUT) do
    if pcall(f, t) then
      setInputIdx = i
      emu.log("setInput variant " .. i)
      return
    end
  end
  setInputFailed = true
  emu.log("setInput failed: the controller is not blocked while typing")
end

-- inputPolled callback
function M.onInput()
  if state.pressA and state.pressA > 0 then
    state.pressA = state.pressA - 1
    send(PRESS_A)  -- closes the game dialog box
    return
  end
  if not state.chat.active then return end
  send(NONE)       -- block the controller while typing
end

-- ---------------------------------------------------------------
-- Per frame update
-- ---------------------------------------------------------------
function M.update()
  local session = state.session
  if not session then
    state.chat.active, state.chat.input = false, ""
    return
  end
  -- The dialog box is gone (the player closed it): end the session
  if not isBorder(tile(prevAddr(session.first))) then
    closeChat()
    return
  end
  local pressed, shift = pollKeys()
  if not session.primed then
    -- First frame: keys already held (e.g. the button that closed the
    -- previous text) must not count as typed
    session.primed = true
    drawChat()
    return
  end
  for _, id in ipairs(pressed) do
    if C.DEBUG_KEYS then emu.log("KEY PRESSED: " .. id) end
    if not state.session then break end
    handleKey(id, shift)
  end
  drawChat()
end

return M