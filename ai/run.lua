local FLUSH_FRAMES = 30
local PUNCT = { [0xBF] = ",", [0xC4] = "!" }
local SPRITE_ROUTINE = 0xE301
local PLAYER_FROM = 0xE414
local MAP_ID = 0x48
local CONFIG_FILE = "prompts.lua"
local REPLACE_TEXT = true   -- replace the displayed dialog with the generated text
local REPLACE_DELAY = 4     -- frames without writes before a dialog is considered complete
local MAX_TALK_DIST = 24    -- max pixel distance (|dx|+|dy|) between player and talking NPC

-- ---------------------------------------------------------------
-- Prompt config:
-- return { general = "...", npcs = { [map id] = { [character id] = "prompt" } } }
-- ---------------------------------------------------------------
local CONFIG = {}

-- Candidate locations for prompts.lua, in order of priority:
-- 1. next to the script (same directory as the script)
-- 2. the Mesen script data folder (may be a non-string in some setups)
-- 3. $FF1_PROMPTS, then $PWD/ai/prompts.lua (launch directory)
-- 4. relative paths (ai/prompts.lua, prompts.lua), last resort
local function configCandidates()
  local list = {}
  if debug and debug.getinfo then
    local src = debug.getinfo(1, "S").source or ""
    emu.log("Script source: " .. src)
    local d = src:match("^[@=](.*)[/\\][^/\\]*$")
    if d then list[#list + 1] = d .. "/" .. CONFIG_FILE end
  end
  local dir = emu.getScriptDataFolder()
  if type(dir) == "string" and dir ~= "" then
    list[#list + 1] = dir .. "/" .. CONFIG_FILE
  end
  -- Mesen only reports the script file name (no directory) and its working
  -- directory is not the launch directory, so relative paths fail. Use the
  -- shell environment instead: an explicit override, then $PWD (the directory
  -- Mesen was launched from, i.e. the repository root).
  if os and os.getenv then
    local override = os.getenv("FF1_PROMPTS")
    if override and override ~= "" then list[#list + 1] = override end
    local pwd = os.getenv("PWD")
    if pwd and pwd ~= "" then
      list[#list + 1] = pwd .. "/ai/" .. CONFIG_FILE
      list[#list + 1] = pwd .. "/" .. CONFIG_FILE
    end
  end
  list[#list + 1] = "ai/" .. CONFIG_FILE
  list[#list + 1] = CONFIG_FILE
  return list
end

local function loadConfig()
  local f, path
  for _, p in ipairs(configCandidates()) do
    f = io.open(p, "r")
    if f then path = p; break end
    emu.log("Config not found: " .. p)
  end
  if not f then return end
  local src = f:read("*a")
  f:close()
  -- Run the config in an empty environment: it only has to return a table
  local chunk, err = load(src, "@" .. path, "t", {})
  local ok, t = false, err
  if chunk then ok, t = pcall(chunk) end
  if ok and type(t) == "table" then
    CONFIG = t
    emu.log("Config loaded: " .. path)
  else
    emu.log("Invalid config: " .. tostring(t))
  end
end

-- Character prompt for an NPC: CONFIG.npcs[map id][character id]
local function promptFor(map, off)
  local m = CONFIG.npcs and CONFIG.npcs[map]
  return m and m[off]
end

-- Full prompt sent to the LLM: general instructions (CONFIG.general, sent
-- every time), then the character prompt, then the original captured text.
local function buildPrompt(npcPrompt, original)
  return (CONFIG.general or "") .. "\n\n"
    .. "Character: " .. npcPrompt .. "\n\n"
    .. "Original text: " .. original
end

loadConfig()

-- ---------------------------------------------------------------
-- LLM call (fake for now, to be replaced by a llama.cpp request)
-- ---------------------------------------------------------------
-- Returns the text the NPC should say. Only letters, digits, space, ',' and
-- '!' can be displayed by the game font used here.
local function fakeLLM(map, off, prompt)
  emu.log("LLM PROMPT:\n---\n" .. prompt .. "\n---")
  return string.format("WIP %02X %02X", map, off)
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
local function encode(ch)
  if ch == "" then return 0xFF end
  if ch:match("%d") then return 0x80 + ch:byte() - 0x30 end
  if ch:match("%u") then return 0x8A + ch:byte() - 0x41 end
  if ch:match("%l") then return 0xA4 + ch:byte() - 0x61 end
  if ch == "," then return 0xBF end
  if ch == "!" then return 0xC4 end
  return 0xFF
end

-- Next nametable address (wraps within the 32 tile row)
local function nextAddr(a)
  if (a & 31) == 31 then return (a ~ 0x400) & ~0x1F end
  return a + 1
end

local function rd(a) return emu.read(a, emu.memType.nesMemory) end
local function ppuWrite(a, v) emu.write(a, v, emu.memType.nesPpuMemory) end

local function normalize(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
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
    -- Start of a new text: snapshot the context
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

  -- Blank the tile for now (the text is written back in flush). Leading
  -- blanks (box clearing) are kept untouched: blanking starts at the first
  -- real character.
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
    if isText then
      -- The whole original text is known: ask the LLM and write its answer
      -- over the blanked tiles.
      local out = fakeLLM(startMap, startOff, buildPrompt(startPrompt, text))
      for k, addr in ipairs(addrs) do ppuWrite(addr, encode(out:sub(k, k))) end
      emu.log("REPLACED: " .. out)
    else
      -- Not a dialog after all: put the original tiles back
      for k, addr in ipairs(addrs) do ppuWrite(addr, vals[k]) end
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

local function onFrame()
  frame = frame + 1
  if #buf > 0 then
    local wait = replActive and REPLACE_DELAY or FLUSH_FRAMES
    if frame - lastFrame >= wait then flush() end
  end
end

emu.addMemoryCallback(onCtrl,   emu.callbackType.write, 0x2000, 0x2000)
emu.addMemoryCallback(onStatus, emu.callbackType.read,  0x2002, 0x2002)
emu.addMemoryCallback(onAddr,   emu.callbackType.write, 0x2006, 0x2006)
emu.addMemoryCallback(onData,   emu.callbackType.write, 0x2007, 0x2007)
emu.addMemoryCallback(onSprite, emu.callbackType.exec,  SPRITE_ROUTINE, SPRITE_ROUTINE)
emu.addEventCallback(onFrame, emu.eventType.endFrame)