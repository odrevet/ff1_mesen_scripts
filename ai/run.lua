
-- Entry point of the FF1 AI script. Holds the settings you may want to tweak,
-- loads the modules from ai/lib/ and registers the Mesen callbacks.

local C = {
  FLUSH_FRAMES   = 30,
  SPRITE_ROUTINE = 0xE301,
  PLAYER_FROM    = 0xE414,
  MAP_ID         = 0x48,
  PROMPTS_FILE   = "prompts.lua",
  SETTINGS_FILE  = "config.lua",
  REPLACE_TEXT   = true,  -- replace the displayed dialog with the generated text
  REPLACE_DELAY  = 4,     -- frames without writes before a dialog is considered complete
  MAX_TALK_DIST  = 24,    -- max pixel distance (|dx|+|dy|) between player and talking NPC

  -- Chat with the NPC (keyboard input drawn as an overlay)
  DEBUG_KEYS     = false, -- log every key detected while typing (to check the key names)
  MAX_INPUT      = 64    -- max characters of a player message
}

-- State shared between modules
local state = {
  frame = 0,
  session = nil,                       -- open chat session (see capture.lua)
  chat = { active = false, input = "" },
}

-- ---------------------------------------------------------------
-- Module loader
-- ---------------------------------------------------------------
-- Mesen only reports the script file name (no directory) and its working
-- directory is not the launch directory, so modules are searched like the
-- config files. Candidate locations of lib/<name>.lua, in order:
-- 1. the Mesen script data folder
-- 2. $FF1_DIR/lib, then $PWD/ai/lib (run Mesen from the repository root)
-- 3. relative paths (ai/lib, lib), last resort
local function modulePaths(name)
  local file = "lib/" .. name .. ".lua"
  local list = {}
  local dir = emu.getScriptDataFolder()
  if type(dir) == "string" and dir ~= "" then
    list[#list + 1] = dir .. "/" .. file
  end
  if os and os.getenv then
    local base = os.getenv("FF1_DIR")
    if base and base ~= "" then list[#list + 1] = base .. "/" .. file end
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

local ctx = { C = C, state = state }
local cache = {}

-- Load a module once. A module is a Lua chunk that receives ctx as its
-- only argument and returns a table.
function ctx.use(name)
  if cache[name] then return cache[name] end
  local tried = {}
  for _, p in ipairs(modulePaths(name)) do
    local f = io.open(p, "r")
    if f then
      local src = f:read("*a")
      f:close()
      local chunk, err = load(src, "@" .. p)
      if not chunk then error("Cannot compile " .. p .. ": " .. tostring(err)) end
      local mod = chunk(ctx)
      cache[name] = mod
      emu.log("Module: " .. p)
      return mod
    end
    tried[#tried + 1] = p
  end
  error("Module '" .. name .. "' not found. Tried:\n" .. table.concat(tried, "\n"))
end

-- ---------------------------------------------------------------
-- Modules and callbacks
-- ---------------------------------------------------------------
ctx.use("settings")  -- load the config files first so problems are logged early
local capture = ctx.use("capture")
local npc = ctx.use("npc")
local ui = ctx.use("ui")

local function onFrame()
  state.frame = state.frame + 1
  capture.tick()
  ui.update()
end

emu.addMemoryCallback(capture.onCtrl,   emu.callbackType.write, 0x2000, 0x2000)
emu.addMemoryCallback(capture.onStatus, emu.callbackType.read,  0x2002, 0x2002)
emu.addMemoryCallback(capture.onAddr,   emu.callbackType.write, 0x2006, 0x2006)
emu.addMemoryCallback(capture.onData,   emu.callbackType.write, 0x2007, 0x2007)
emu.addMemoryCallback(npc.onSprite,     emu.callbackType.exec,  C.SPRITE_ROUTINE, C.SPRITE_ROUTINE)
emu.addEventCallback(onFrame,           emu.eventType.endFrame)
emu.addEventCallback(ui.onInput,        emu.eventType.inputPolled)
