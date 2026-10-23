local FLUSH_FRAMES = 30
local PUNCT = { [0xBF] = ",", [0xC4] = "!" }
local SPRITE_ROUTINE = 0xE301
local PLAYER_FROM = 0xE414
local MAP_ID = 0x48
local PROMPTS_FILE = "prompts.lua"
local SETTINGS_FILE = "config.lua"
local REPLACE_TEXT = true   -- replace the displayed dialog with the generated text
local REPLACE_DELAY = 4     -- frames without writes before a dialog is considered complete
local MAX_TALK_DIST = 24    -- max pixel distance (|dx|+|dy|) between player and talking NPC

-- Chat with the NPC (keyboard input drawn as an overlay)
local DEBUG_KEYS = false  -- log every key detected while typing (to check the key names)
local MAX_INPUT = 60        -- max characters of a player message
local DEFAULT_CHAT = "You are an NPC in the NES game Final Fantasy 1. Stay in character and answer the player, who is the hero, in a short conversation. Reply with one short line only. Use only letters, digits, spaces, commas and exclamation marks. Keep it under 60 characters."

-- ---------------------------------------------------------------
-- Config files (Lua tables, see prompts.lua and config.lua)
-- ---------------------------------------------------------------
-- Candidate locations for a config file, in order of priority:
-- 1. the Mesen script data folder (may be a non-string in some setups)
-- 2. $FF1_<NAME> (e.g. FF1_PROMPTS, FF1_CONFIG), then $PWD/ai/<file>
-- 3. relative paths (ai/<file>, <file>), last resort
-- Mesen only reports the script file name (no directory) and its working
-- directory is not the launch directory, so $PWD (the directory Mesen was
-- launched from, i.e. the repository root) is used.
local function candidates(file)
  local list = {}
  local dir = emu.getScriptDataFolder()
  if type(dir) == "string" and dir ~= "" then
    list[#list + 1] = dir .. "/" .. file
  end
  if os and os.getenv then
    local env = "FF1_" .. (file:gsub("%.lua$", "")):upper()
    local override = os.getenv(env)
    if override and override ~= "" then list[#list + 1] = override end
    local pwd = os.getenv("PWD")
    if pwd and pwd ~= "" then
      list[#list + 1] = pwd .. "/ai/" .. file
      list[#list + 1] = pwd .. "/" .. file
    end
  end
  list[#list + 1] = "ai/" .. file
  list[#list + 1] = file
  return list
end

-- Load a config file: a Lua chunk that returns a table. It runs in an empty
-- environment, so it cannot call any function.
local function loadLuaFile(file)
  local f, path
  for _, p in ipairs(candidates(file)) do
    f = io.open(p, "r")
    if f then path = p; break end
    emu.log("Not found: " .. p)
  end
  if not f then return {} end
  local src = f:read("*a")
  f:close()
  local chunk, err = load(src, "@" .. path, "t", {})
  local ok, t = false, err
  if chunk then ok, t = pcall(chunk) end
  if ok and type(t) == "table" then
    emu.log("Loaded: " .. path)
    return t
  end
  emu.log("Invalid " .. file .. ": " .. tostring(t))
  return {}
end

local PROMPTS = loadLuaFile(PROMPTS_FILE)
local SETTINGS = loadLuaFile(SETTINGS_FILE)

-- Character prompt for an NPC: PROMPTS.npcs[map id][character id]
local function promptFor(map, off)
  local m = PROMPTS.npcs and PROMPTS.npcs[map]
  return m and m[off]
end

-- Prompt sent to the LLM. The general instructions (PROMPTS.general) are the
-- system message and are sent every time; the user message holds the
-- character prompt and the original captured text.
local function buildPrompt(npcPrompt, original)
  return PROMPTS.general or "",
    "Character: " .. npcPrompt .. "\n\nOriginal text: " .. original
end

-- System message of a chat (PROMPTS.chat, optional, else DEFAULT_CHAT)
local function chatSystem(npcPrompt, original)
  return (PROMPTS.chat or DEFAULT_CHAT)
    .. "\n\nCharacter: " .. npcPrompt
    .. "\nOriginal line of this NPC in the game: " .. original
end

-- ---------------------------------------------------------------
-- FF1 text decoding / encoding
-- ---------------------------------------------------------------
local function decode(t)
  if t >= 0x80 and t <= 0x89 then return string.char(0x30 + t - 0x80) end
  if t >= 0x8A and t <= 0xA3 then return string.char(0x41 + t - 0x8A) end
  if t >= 0xA4 and t <= 0xBD then return string.char(0x61 + t - 0xA4) end
  if t == 0xFF then return " " end
  return PUNCT[t]
end

-- Inverse of decode(): character to FF1 tile ID (unknown characters become a space)
local ENC = { [" "] = 0xFF }
for t, c in pairs(PUNCT) do ENC[c] = t end

local function encode(c)
  if c == "" then return 0xFF end
  if ENC[c] then return ENC[c] end
  local b = c:byte()
  if b >= 0x30 and b <= 0x39 then return 0x80 + b - 0x30 end
  if b >= 0x41 and b <= 0x5A then return 0x8A + b - 0x41 end
  if b >= 0x61 and b <= 0x7A then return 0xA4 + b - 0x61 end
  return 0xFF
end

-- Next nametable address (wraps within the 32 tile row)
local function nextAddr(a)
  if (a & 31) == 31 then return (a ~ 0x400) & ~0x1F end
  return a + 1
end

-- Previous nametable address (wraps within the 32 tile row)
local function prevAddr(a)
  if (a & 31) == 0 then return (a ~ 0x400) | 0x1F end
  return a - 1
end

local function rd(a) return emu.read(a, emu.memType.nesMemory) end
-- Nametable RAM is what the PPU displays; & 0x7FF handles the 2KB of RAM
local function tile(a) return emu.read(a & 0x7FF, emu.memType.nesNametableRam) end
local function writeTile(a, v) emu.write(a & 0x7FF, v, emu.memType.nesNametableRam) end

local function normalize(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- FF1 dialog box border tiles
local function isBorder(t) return t >= 0xF7 and t <= 0xFE end

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
local function writeBox(first, width, lines, text)
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
local function writeAnswer(addrs, text)
  if #addrs == 0 then return nil end
  local first, width, lines = dialogArea(addrs)
  emu.log(string.format("BOX first=%04X width=%d lines=%d", first, width, lines))
  if width < 1 or lines < 1 then return nil end
  writeBox(first, width, lines, text)
  return first, width, lines
end

-- ---------------------------------------------------------------
-- LLM call (llama.cpp server over HTTP)
-- ---------------------------------------------------------------
local function jsonString(s)
  local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
  local escaped = s:gsub('[%c"\\]', function(c)
    return map[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

-- Extract the first "content" string value of a JSON response
local function jsonContent(body)
  local _, e = body:find('"content"%s*:%s*"')
  if not e then return nil end
  local j, out = e + 1, {}
  local esc = { n = "\n", t = "\t", r = "\r" }
  while true do
    local c = body:sub(j, j)
    if c == "" then return nil end
    if c == '"' then break end
    if c == "\\" then
      j = j + 1
      c = body:sub(j, j)
      if c == "u" then
        out[#out + 1] = utf8.char(tonumber(body:sub(j + 1, j + 4), 16) or 63)
        j = j + 4
      else
        out[#out + 1] = esc[c] or c
      end
    else
      out[#out + 1] = c
    end
    j = j + 1
  end
  return table.concat(out)
end

-- Decode an HTTP "Transfer-Encoding: chunked" body
local function dechunk(s)
  local out, i = {}, 1
  while true do
    local nl = s:find("\r\n", i, true)
    if not nl then break end
    local hex = s:sub(i, nl - 1):match("^%x+")
    local n = hex and tonumber(hex, 16)
    if not n or n == 0 then break end
    out[#out + 1] = s:sub(nl + 2, nl + 1 + n)
    i = nl + 2 + n + 2
  end
  return table.concat(out)
end

-- Minimal blocking HTTP POST over Mesen's socket library (needs "Allow
-- network access"; http:// only). Returns the response body and the HTTP
-- status, or nil and an error message.
local function httpPost(url, body, timeout)
  local ok, socket = pcall(require, "socket")
  if not ok then
    return nil, "socket library unavailable, is network access allowed? " .. tostring(socket)
  end
  local host, port, path = url:match("^http://([^/:]+):?(%d*)(/?.*)$")
  if not host then return nil, "unsupported url (http:// only): " .. url end
  port = tonumber(port) or 80
  if path == "" then path = "/" end

  local c = socket.tcp()
  c:settimeout(timeout)
  local connected, cerr = c:connect(host, port)
  if not connected then
    c:close()
    return nil, "connect failed: " .. tostring(cerr)
  end
  local req = table.concat({
    "POST " .. path .. " HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "Content-Type: application/json",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body,
  }, "\r\n")
  local sent, serr = c:send(req)
  if not sent then
    c:close()
    return nil, "send failed: " .. tostring(serr)
  end
  -- "Connection: close": the server closes the socket once the answer is sent
  local data, rerr, partial = c:receive("*a")
  c:close()
  data = data or partial
  if not data or data == "" then return nil, "no response: " .. tostring(rerr) end
  local head, rest = data:match("^(.-)\r\n\r\n(.*)$")
  if not head then return nil, "malformed response" end
  if head:lower():find("transfer%-encoding:%s*chunked") then rest = dechunk(rest) end
  return rest, head:match("^HTTP/%S+ (%d+)")
end

-- Blocking request: the emulator is frozen until the server answers (or
-- the timeout expires). `messages` is a list of { role=, content= }.
-- Returns the answer text, or nil and an error.
local function llmRequest(S, messages)
  local parts = {}
  for i, m in ipairs(messages) do
    parts[i] = '{"role":' .. jsonString(m.role) .. ',"content":' .. jsonString(m.content) .. "}"
  end
  local body = string.format(
    '{%s"messages":[%s],"max_tokens":%d,"temperature":%s,"stream":false}',
    S.model and ('"model":' .. jsonString(S.model) .. ",") or "",
    table.concat(parts, ","),
    S.max_tokens or 64, tostring(S.temperature or 0.8))

  local resp, status = httpPost(S.url, body, S.timeout or 30)
  if not resp then return nil, status end
  local text = jsonContent(resp)
  if not text then return nil, "HTTP " .. tostring(status) .. ": " .. resp:sub(1, 200) end
  return text
end

-- Keep only what the game font can display: letters, digits, space, ',' '!'
local function sanitize(s)
  s = s:gsub("%c", " ")
  s = s:gsub("[^%w ,!]", "")
  return normalize(s)
end

-- Fake answer used when config.lua sets fake = true or has no url
local function fakeLLM(map, off)
  return string.format("WIP %02X %02X", map, off)
end

-- Returns the text the NPC should say, or nil on failure
local function generate(map, off, system, user)
  emu.log("LLM PROMPT:\n---\n" .. system .. "\n\n" .. user .. "\n---")
  local S = SETTINGS.llm or {}
  if S.fake or not S.url then return fakeLLM(map, off) end
  local raw, err = llmRequest(S, {
    { role = "system", content = system },
    { role = "user", content = user },
  })
  if not raw then
    emu.log("LLM error: " .. tostring(err))
    return nil
  end
  emu.log("LLM RAW: " .. raw)
  local out = sanitize(raw)
  if out == "" then
    emu.log("LLM answer is empty after cleanup")
    return nil
  end
  return out
end

-- Chat reply: the full conversation is sent on every call
local function chatReply(messages)
  local S = SETTINGS.llm or {}
  if S.fake or not S.url then return "WIP " .. #messages end
  local raw, err = llmRequest(S, messages)
  if not raw then
    emu.log("LLM error: " .. tostring(err))
    return nil
  end
  emu.log("LLM RAW: " .. raw)
  local out = sanitize(raw)
  if out == "" then
    emu.log("LLM answer is empty after cleanup")
    return nil
  end
  return out
end

-- ---------------------------------------------------------------
-- State
-- ---------------------------------------------------------------
local latch, ppuAddr, inc = false, 0, 1
local buf, lastAddr, lastFrame, frame = {}, nil, 0, 0
local cur, prev, curFrame = {}, {}, -1
local startList, startMap, startAux, startPX, startPY

-- Replacement of the current dialog. While a configured NPC talks, the
-- original tiles are blanked and remembered; once the dialog is complete the
-- LLM text is written over them.
local replActive, replAddrs, replVals = false, {}, {}
local replStarted, startOff, startPrompt = false, nil, nil

-- Chat session with the NPC whose answer is displayed: the dialog box
-- (first interior tile, width, lines) and the whole conversation.
local session = nil
local chat = { active = false, input = "" }

-- Record each sprite drawn by the game routine (position, pointer, caller)
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

-- Find the NPC closest to the player (the one who is talking)
local function findTalker(list)
  local player
  for _, s in ipairs(list) do
    if s.from == PLAYER_FROM then player = s; break end
  end
  if not player then return nil, "player not found" end
  local best, bestD
  for _, s in ipairs(list) do
    if s.from ~= PLAYER_FROM then
      local d = math.abs(s.x - player.x) + math.abs(s.y - player.y)
      if not bestD or d < bestD then best, bestD = s, d end
    end
  end
  if not best then return nil, "no NPC" end
  return best, best.x - player.x, best.y - player.y
end

-- ---------------------------------------------------------------
-- PPU callbacks
-- ---------------------------------------------------------------
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
  -- Keep only nametable tiles, skip attribute tables
  if a < 0x2000 or a >= 0x3000 or (a & 0x3FF) >= 0x3C0 then return end
  local c = decode(val)
  if not c then return end
  if #buf == 0 then
    -- Start of a new text: snapshot the context, drop the previous chat
    session, chat.active, chat.input = nil, false, ""
    startList = copyList(#prev > 0 and prev or cur)
    startMap, startAux = rd(MAP_ID), rd(MAP_ID + 1)
    startPX, startPY = rd(0x68), rd(0x69)

    -- Decide whether this dialog gets replaced: the talker must be next to
    -- the player and have a prompt in the config.
    replActive, replAddrs, replVals, replStarted = false, {}, {}, false
    if REPLACE_TEXT then
      local t, dx, dy = findTalker(startList)
      if t and type(dx) == "number" and math.abs(dx) + math.abs(dy) <= MAX_TALK_DIST then
        local p = promptFor(startMap, t.off)
        if p then
          replActive, startOff, startPrompt = true, t.off, p
        end
      end
    end
  end
  if lastAddr and a ~= nextAddr(lastAddr) then buf[#buf + 1] = " " end
  buf[#buf + 1] = c
  lastAddr, lastFrame = a, frame

  -- Blank the tile for now (the original text is restored in flush when the
  -- LLM fails). Leading blanks (box clearing) are kept untouched: blanking
  -- starts at the first real character.
  if replActive then
    if c ~= " " then replStarted = true end
    if replStarted then
      replAddrs[#replAddrs + 1] = a
      replVals[#replVals + 1] = val
      return 0xFF
    end
  end
end

-- ---------------------------------------------------------------
-- End of dialogue
-- ---------------------------------------------------------------
local function flush()
  local text = normalize(table.concat(buf))
  local active, addrs, vals = replActive, replAddrs, replVals
  buf, lastAddr = {}, nil
  replActive, replAddrs, replVals = false, {}, {}
  local isText = text:match("%l%l%l") ~= nil -- ignore map loading noise

  if active then
    local out
    if isText then
      -- The whole original text is known: ask the LLM
      local system, user = buildPrompt(startPrompt, text)
      out = generate(startMap, startOff, system, user)
    end
    if out and #addrs > 0 then
      -- Write the answer over the blanked tiles, as in-game text
      local first, width, lines = writeAnswer(addrs, out)
      emu.log("REPLACED: " .. out)
      if first then
        -- Open a chat session: the conversation starts with this answer
        session = {
          first = first, width = width, lines = lines,
          messages = {
            { role = "system", content = chatSystem(startPrompt, text) },
            { role = "user", content = "*the player walks up to you*" },
            { role = "assistant", content = out },
          },
          primed = false,
        }
        chat.active, chat.input = true, ""
        emu.log("CHAT OPEN: type your message, Enter to send, empty Enter to close")
      end
    elseif not out then
      -- Not a dialog, or the LLM failed: put the original tiles back
      for k, addr in ipairs(addrs) do writeTile(addr, vals[k]) end
    end
  end

  if not isText then return end
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
  local p = promptFor(startMap, t.off)
  emu.log("NPC PROMPT: " .. (p or "(none)"))
end

-- ---------------------------------------------------------------
-- Chat: keyboard input box
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

-- Send the typed message with the whole conversation, show the answer
local function submit()
  local msg = sanitize(chat.input)
  chat.input = ""
  if msg == "" then return end
  local s = session
  s.messages[#s.messages + 1] = { role = "user", content = msg }
  emu.log("PLAYER: " .. msg)
  local reply = chatReply(s.messages)
  if not reply then
    s.messages[#s.messages] = nil
    return
  end
  s.messages[#s.messages + 1] = { role = "assistant", content = reply }
  writeBox(s.first, s.width, s.lines, reply)
  emu.log("CHAT NPC: " .. reply)
end

local function handleKey(id, shift)
  if id == "enter" then
    if sanitize(chat.input) == "" then
      emu.log("CHAT CLOSED")
      session, chat.active, chat.input = nil, false, ""
    else
      submit()
    end
  elseif id == "back" then
    chat.input = chat.input:sub(1, -2)
  elseif #chat.input < MAX_INPUT then
    if id == "space" then
      chat.input = chat.input .. " "
    elseif id == "comma" then
      chat.input = chat.input .. ","
    elseif id:match("^%d$") then
      chat.input = chat.input .. ((shift and id == "1") and "!" or id)
    elseif id:match("^%a$") then
      chat.input = chat.input .. (shift and id or id:lower())
    end
  end
end

-- Overlay styled like the FF1 dialog window (same margins as the game box:
-- 16 px from the left edge, 224 px wide). Colors are 0xAARRGGBB with an
-- inverted alpha: 0x00 opaque, 0xFF transparent.
local BOX_X, BOX_Y, BOX_W, BOX_H = 16, 176, 224, 40
local COL_BG    = 0x0000238C   -- window blue
local COL_WHITE = 0x00FFFFFF   -- text and outer frame
local COL_GRAY  = 0x00B4B4BC   -- inner frame line
local COL_BLACK = 0x00000000   -- outline around the window
local COL_HINT  = 0x00B4B4BC

local function drawFrame(x, y, w, h)
  emu.drawRectangle(x - 1, y - 1, w + 2, h + 2, COL_BLACK, false, 1)
  emu.drawRectangle(x, y, w, h, COL_BG, true, 1)
  emu.drawRectangle(x, y, w, h, COL_WHITE, false, 1)
  emu.drawRectangle(x + 1, y + 1, w - 2, h - 2, COL_WHITE, false, 1)
  emu.drawRectangle(x + 2, y + 2, w - 4, h - 4, COL_GRAY, false, 1)
end

local function drawChat()
  if not chat.active then return end
  local shown = chat.input
  if #shown > 31 then shown = shown:sub(-31) end
  local cursor = ((frame // 20) % 2 == 0) and "_" or " "
  drawFrame(BOX_X, BOX_Y, BOX_W, BOX_H)
  -- drawString(x, y, text, color, backColor, maxWidth, duration): without a
  -- maxWidth the text wraps after every character.
  emu.drawString(BOX_X + 10, BOX_Y + 11, "> " .. shown .. cursor,
    COL_WHITE, 0xFF000000, BOX_W - 20, 1)
  emu.drawString(BOX_X + 10, BOX_Y + 24, "Enter: send (empty: close)",
    COL_HINT, 0xFF000000, BOX_W - 20, 1)
end

-- While typing, the controller is disabled so the game does not react
local BLOCK = { a = false, b = false, select = false, start = false,
                up = false, down = false, left = false, right = false }
-- The setInput signature differs between Mesen versions: try each one
local SET_INPUT = {
  function() emu.setInput(0, BLOCK) end,
  function() emu.setInput(BLOCK, 0) end,
  function() emu.setInput(BLOCK, 0, 0) end,
  function() emu.setInput(0, 0, BLOCK) end,
}
local setInputIdx, setInputFailed = nil, false

local function onInput()
  if not chat.active then return end
  if setInputIdx then pcall(SET_INPUT[setInputIdx]); return end
  if setInputFailed then return end
  for i, f in ipairs(SET_INPUT) do
    if pcall(f) then
      setInputIdx = i
      emu.log("setInput variant " .. i)
      return
    end
  end
  setInputFailed = true
  emu.log("setInput failed: the controller is not blocked while typing")
end

local function updateChat()
  if not session then
    chat.active, chat.input = false, ""
    return
  end
  -- The dialog box is gone (the player closed it): end the session
  if not isBorder(tile(prevAddr(session.first))) then
    session, chat.active, chat.input = nil, false, ""
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
    if DEBUG_KEYS then emu.log("KEY PRESSED: " .. id) end
    if not session then break end
    handleKey(id, shift)
  end
  drawChat()
end

local function onFrame()
  frame = frame + 1
  if #buf > 0 then
    local wait = replActive and REPLACE_DELAY or FLUSH_FRAMES
    if frame - lastFrame >= wait then flush() end
  end
  updateChat()
end

emu.addMemoryCallback(onCtrl,   emu.callbackType.write, 0x2000, 0x2000)
emu.addMemoryCallback(onStatus, emu.callbackType.read,  0x2002, 0x2002)
emu.addMemoryCallback(onAddr,   emu.callbackType.write, 0x2006, 0x2006)
emu.addMemoryCallback(onData,   emu.callbackType.write, 0x2007, 0x2007)
emu.addMemoryCallback(onSprite, emu.callbackType.exec,  SPRITE_ROUTINE, SPRITE_ROUTINE)
emu.addEventCallback(onFrame, emu.eventType.endFrame)
emu.addEventCallback(onInput, emu.eventType.inputPolled)