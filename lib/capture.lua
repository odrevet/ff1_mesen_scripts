-- Dialog capture: PPU callbacks, blanking of the original text, and the
-- replacement by the LLM answer once the dialog is complete.
local ctx = ...
local C, state = ctx.C, ctx.state
local ff1 = ctx.use("ff1")
local settings = ctx.use("settings")
local npc = ctx.use("npc")
local llm = ctx.use("llm")
local dialog = ctx.use("dialog")

local decode, nextAddr, rd = ff1.decode, ff1.nextAddr, ff1.rd
local writeTile, normalize = ff1.writeTile, ff1.normalize
local promptFor = settings.promptFor

local M = {}

-- PPU write tracking
local latch, ppuAddr, inc = false, 0, 1
local buf, lastAddr, lastFrame = {}, nil, 0
local startList, startMap, startAux, startPX, startPY

-- Replacement of the current dialog. While a configured NPC talks, the
-- original tiles are blanked and remembered; once the dialog is complete the
-- LLM text is written over them.
local replActive, replAddrs, replVals = false, {}, {}
local replStarted, startOff, startPrompt = false, nil, nil

-- ---------------------------------------------------------------
-- PPU callbacks
-- ---------------------------------------------------------------
function M.onCtrl(addr, val) inc = ((val & 4) ~= 0) and 32 or 1 end
function M.onStatus() latch = false end

function M.onAddr(addr, val)
  if not latch then ppuAddr = (val & 0x3F) << 8
  else ppuAddr = (ppuAddr & 0xFF00) | val end
  latch = not latch
end

function M.onData(addr, val)
  local a = ppuAddr
  ppuAddr = (ppuAddr + inc) & 0x3FFF
  -- Keep only nametable tiles, skip attribute tables
  if a < 0x2000 or a >= 0x3000 or (a & 0x3FF) >= 0x3C0 then return end
  local c = decode(val)
  if not c then return end
  if #buf == 0 then
    -- Start of a new text: snapshot the context, drop the previous chat
    state.session, state.chat.active, state.chat.input = nil, false, ""
    startList = npc.snapshot()
    startMap, startAux = rd(C.MAP_ID), rd(C.MAP_ID + 1)
    startPX, startPY = rd(0x68), rd(0x69)

    -- Decide whether this dialog gets replaced: the talker must be next to
    -- the player and have a prompt in the config.
    replActive, replAddrs, replVals, replStarted = false, {}, {}, false
    if C.REPLACE_TEXT then
      local t, dx, dy = npc.findTalker(startList)
      if t and type(dx) == "number" and math.abs(dx) + math.abs(dy) <= C.MAX_TALK_DIST then
        local p = promptFor(startMap, t.off)
        if p then
          replActive, startOff, startPrompt = true, t.off, p
        end
      end
    end
  end
  if lastAddr and a ~= nextAddr(lastAddr) then buf[#buf + 1] = " " end
  buf[#buf + 1] = c
  lastAddr, lastFrame = a, state.frame

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
      local system, user = settings.buildPrompt(startPrompt, text)
      out = llm.generate(startMap, startOff, system, user)
    end
    if out and #addrs > 0 then
      -- Write the answer over the blanked tiles, as in-game text
      local first, width, lines = dialog.writeAnswer(addrs, out)
      emu.log("REPLACED: " .. out)
      if first and C.CHAT then
        -- Open a chat session: the conversation starts with this answer
        state.session = {
          first = first, width = width, lines = lines,
          messages = {
            { role = "system", content = settings.chatSystem(startPrompt, text) },
            { role = "user", content = "Hello" },
            { role = "assistant", content = out },
          },
          primed = false,
        }
        state.chat.active, state.chat.input = true, ""
      end
    elseif not out then
      -- Not a dialog, or the LLM failed: put the original tiles back
      for k, addr in ipairs(addrs) do writeTile(addr, vals[k]) end
    end
  end

  if not isText then return end
  emu.log("TEXT: " .. text)
  local t, dx, dy = npc.findTalker(startList or {})
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

-- Called every frame: a dialog is complete once no tile was written for a while
function M.tick()
  if #buf > 0 then
    local wait = replActive and C.REPLACE_DELAY or C.FLUSH_FRAMES
    if state.frame - lastFrame >= wait then flush() end
  end
end

return M
