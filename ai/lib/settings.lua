-- Config files (Lua tables, see prompts.lua and config.lua) and prompt building.
local ctx = ...
local C = ctx.C

local M = {}

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

M.PROMPTS = loadLuaFile(C.PROMPTS_FILE)
M.SETTINGS = loadLuaFile(C.SETTINGS_FILE)

-- Used when an NPC has no prompt in PROMPTS.npcs (override it with a
-- "default" key in prompts.lua)
local DEFAULT_CHARACTER =
  "A character in Final Fantasy 1 on NES"

-- Character prompt for an NPC: PROMPTS.npcs[map id][character id],
-- or the generic character when the NPC is not mapped
function M.promptFor(map, off)
  local m = M.PROMPTS.npcs and M.PROMPTS.npcs[map]
  local p = m and m[off]
  if p then return p end
  emu.log("NPC not mapped, using default character")
  return M.PROMPTS.default or DEFAULT_CHARACTER
end

-- Prompt sent to the LLM. The general instructions (PROMPTS.general) are the
-- system message and are sent every time; the user message holds the
-- character prompt and the original captured text.
function M.buildPrompt(npcPrompt, original)
  return M.PROMPTS.general or "",
    "Character: " .. npcPrompt .. "\n\nOriginal text: " .. original
end

-- System message of a chat: same general instructions as the first line,
-- followed by the character and the original line.
function M.chatSystem(npcPrompt, original)
  return (M.PROMPTS.general or "")
    .. "\n\nCharacter: " .. npcPrompt
    .. "\nOriginal line of this NPC in the game: " .. original
end

return M