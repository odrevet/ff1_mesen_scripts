-- LLM call (llama.cpp server over HTTP) and answer cleanup.
local ctx = ...
local normalize = ctx.use("ff1").normalize
local SETTINGS = ctx.use("settings").SETTINGS

local M = {}

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
    emu.log(body)


  local resp, status = httpPost(S.url, body, S.timeout or 30)
  if not resp then return nil, status end
  local text = jsonContent(resp)
  if not text then return nil, "HTTP " .. tostring(status) .. ": " .. resp:sub(1, 200) end
  return text
end

-- Keep only what the game font can display: letters, digits, space, ',' '!'
function M.sanitize(s)
  s = s:gsub("%c", " ")
  s = s:gsub("[^%w ,!]", "")
  return normalize(s)
end

-- Fake answer used when config.lua sets fake = true or has no url
local function fakeLLM(map, off)
  return string.format("WIP %02X %02X", map, off)
end

-- Returns the text the NPC should say, or nil on failure
function M.generate(map, off, system, user)
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
  local out = M.sanitize(raw)
  if out == "" then
    emu.log("LLM answer is empty after cleanup")
    return nil
  end
  return out
end

-- Chat reply: the full conversation is sent on every call
function M.chatReply(messages)
  local S = SETTINGS.llm or {}
  if S.fake or not S.url then return "WIP " .. #messages end
  local raw, err = llmRequest(S, messages)
  if not raw then
    emu.log("LLM error: " .. tostring(err))
    return nil
  end
  emu.log("LLM RAW: " .. raw)
  local out = M.sanitize(raw)
  if out == "" then
    emu.log("LLM answer is empty after cleanup")
    return nil
  end
  return out
end

return M
