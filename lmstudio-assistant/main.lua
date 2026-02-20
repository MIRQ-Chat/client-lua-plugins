local mirq = require('mirq')

local cfg = {
  command_prefix = "/ai",
  mention_tokens = {"@ai", "ai"},
  lmstudio_base = "http://127.0.0.1:1234",
  lmstudio_chat_path = "/v1/chat/completions",
  model = "local-model",
  max_reply_chars = 1800,
  max_profile_chars = 1200,
  max_history_chars = 5000,
  max_rag_items = 6,
  mcp_endpoint = "http://127.0.0.1:8788/mcp/call"
}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function starts_with_ci(s, prefix)
  local a = trim(s):lower()
  local b = trim(prefix):lower()
  return a:sub(1, #b) == b
end

local function escape_json(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local function unescape_json(s)
  s = tostring(s or "")
  s = s:gsub("\\n", "\n")
  s = s:gsub("\\r", "\r")
  s = s:gsub("\\t", "\t")
  s = s:gsub('\\"', '"')
  s = s:gsub("\\\\", "\\")
  return s
end

local function split_words(s)
  local out = {}
  for w in tostring(s or ""):lower():gmatch("[%w_]+") do
    out[#out + 1] = w
  end
  return out
end

local function key_channel_enabled(guild_id, channel_id)
  return string.format("policy:g:%s:c:%s:enabled", tostring(guild_id or 0), tostring(channel_id or 0))
end

local function key_member_profile(guild_id, author_id)
  return string.format("profile:g:%s:u:%s", tostring(guild_id or 0), tostring(author_id or 0))
end

local function key_member_history(guild_id, author_id)
  return string.format("history:g:%s:u:%s", tostring(guild_id or 0), tostring(author_id or 0))
end

local function key_channel_fact(guild_id, channel_id, author_id, ts)
  return string.format("fact:g:%s:c:%s:u:%s:t:%s", tostring(guild_id or 0), tostring(channel_id or 0), tostring(author_id or 0), tostring(ts or 0))
end

local function load_history(guild_id, author_id)
  return mirq.memory.get(key_member_history(guild_id, author_id)) or ""
end

local function save_history(guild_id, author_id, history)
  local text = trim(history)
  if #text > cfg.max_history_chars then
    text = text:sub(#text - cfg.max_history_chars + 1)
  end
  mirq.memory.set(key_member_history(guild_id, author_id), text)
end

local function append_history(guild_id, author_id, role, content)
  local line = string.format("%s: %s", role, trim(content))
  local prev = load_history(guild_id, author_id)
  local joined = prev == "" and line or (prev .. "\n" .. line)
  save_history(guild_id, author_id, joined)
end

local function update_profile(evt)
  local pkey = key_member_profile(evt.guild_id, evt.author_id)
  local current = mirq.memory.get(pkey) or ""
  local addition = string.format("%s said: %s", tostring(evt.author_handle or "member"), trim(evt.content or ""))
  local next_text = current == "" and addition or (current .. "\n" .. addition)
  if #next_text > cfg.max_profile_chars then
    next_text = next_text:sub(#next_text - cfg.max_profile_chars + 1)
  end
  mirq.memory.set(pkey, next_text)
end

local function channel_enabled(evt)
  if evt.is_dm then return true end
  return (mirq.memory.get(key_channel_enabled(evt.guild_id, evt.channel_id)) or "0") == "1"
end

local function set_channel_enabled(evt, enabled)
  if evt.is_dm then return end
  mirq.memory.set(key_channel_enabled(evt.guild_id, evt.channel_id), enabled and "1" or "0")
end

local function is_direct_trigger(content, is_dm)
  if is_dm then return true end
  local msg = trim(content)
  if starts_with_ci(msg, cfg.command_prefix) then return true end
  for _, token in ipairs(cfg.mention_tokens) do
    if starts_with_ci(msg, token) then return true end
  end
  return false
end

local function extract_prompt(content)
  local msg = trim(content)
  if starts_with_ci(msg, cfg.command_prefix) then
    return trim(msg:sub(#cfg.command_prefix + 1))
  end
  for _, token in ipairs(cfg.mention_tokens) do
    if starts_with_ci(msg, token) then
      return trim(msg:sub(#token + 1):gsub("^[,:%-]+", ""))
    end
  end
  return msg
end

local function post_reply(evt, text)
  local out = trim(text)
  if out == "" then return end
  if #out > cfg.max_reply_chars then
    out = out:sub(1, cfg.max_reply_chars) .. "\n\n[truncated]"
  end
  if evt.is_dm then
    mirq.dm.post(evt.thread_id or evt.channel_id, out)
  else
    mirq.chat.post(evt.channel_id, out)
  end
end

local function gather_rag_context(evt, prompt)
  local scope = string.format("fact:g:%s:c:%s:", tostring(evt.guild_id or 0), tostring(evt.channel_id or 0))
  local hits = mirq.memory.search(prompt, 24) or {}
  local out = {}
  for _, h in ipairs(hits) do
    if h and h.key and starts_with_ci(h.key, scope) then
      out[#out + 1] = "- " .. tostring(h.value or "")
      if #out >= cfg.max_rag_items then break end
    end
  end
  return table.concat(out, "\n")
end

local function relevant_skills(prompt)
  local words = split_words(prompt)
  local names = mirq.skills.list() or {}
  local picked = {}
  for _, name in ipairs(names) do
    local lname = tostring(name):lower()
    for _, w in ipairs(words) do
      if w == lname or lname:find(w, 1, true) then
        local s = mirq.skills.get(name)
        if s and trim(s) ~= "" then
          picked[#picked + 1] = string.format("[%s]\n%s", name, s)
        end
        break
      end
    end
    if #picked >= 4 then break end
  end
  return table.concat(picked, "\n\n")
end

local function lmstudio_chat(system_prompt, user_prompt)
  local url = cfg.lmstudio_base .. cfg.lmstudio_chat_path
  local body = string.format(
    '{"model":"%s","temperature":0.3,"messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}]}',
    escape_json(cfg.model),
    escape_json(system_prompt),
    escape_json(user_prompt)
  )
  local resp, err = mirq.http.post(url, body)
  if not resp then return nil, (err or "LM Studio request failed") end

  local content = resp:match('"content"%s*:%s*"(.-)"')
  if content and content ~= "" then
    return unescape_json(content), nil
  end

  local msg = resp:match('"message"%s*:%s*"(.-)"')
  if msg and msg ~= "" then
    return nil, unescape_json(msg)
  end

  return nil, "LM Studio response parse failed"
end

local function cmd_help()
  return table.concat({
    "AI assistant commands:",
    "/ai help",
    "/ai enable | /ai disable (for this channel)",
    "/ai remember <fact> (store channel knowledge)",
    "/ai profile (show your working profile)",
    "/ai skill set <name> <text>",
    "/ai skill get <name> | /ai skill list | /ai skill del <name>",
    "/ai mcp <server> <tool> <json-args>",
    "Mention '@ai' to talk, or enable channel auto-assist."
  }, "\n")
end

local function handle_skill_command(evt, rest)
  local action, tail = rest:match("^([%w_-]+)%s*(.*)$")
  action = trim(action):lower()
  tail = trim(tail)

  if action == "list" then
    local names = mirq.skills.list() or {}
    if #names == 0 then
      post_reply(evt, "No saved skills yet.")
    else
      post_reply(evt, "Skills: " .. table.concat(names, ", "))
    end
    return true
  end

  if action == "get" then
    local name = tail
    local s = mirq.skills.get(name)
    if not s then
      post_reply(evt, "Skill not found: " .. name)
    else
      post_reply(evt, string.format("Skill '%s':\n%s", name, s))
    end
    return true
  end

  if action == "del" then
    local name = tail
    if name == "" then
      post_reply(evt, "Usage: /ai skill del <name>")
    else
      mirq.skills.del(name)
      post_reply(evt, "Deleted skill: " .. name)
    end
    return true
  end

  if action == "set" then
    local name, text = tail:match("^([%w_-]+)%s+(.+)$")
    if not name or not text then
      post_reply(evt, "Usage: /ai skill set <name> <text>")
    else
      mirq.skills.set(name, text)
      post_reply(evt, "Saved skill: " .. name)
    end
    return true
  end

  post_reply(evt, "Usage: /ai skill set|get|list|del ...")
  return true
end

local function handle_mcp_command(evt, rest)
  local server, tool, args = rest:match("^([%w_.%-]+)%s+([%w_.%-]+)%s*(.*)$")
  if not server or not tool then
    post_reply(evt, "Usage: /ai mcp <server> <tool> <json-args>")
    return true
  end
  args = trim(args)
  if args == "" then args = "{}" end

  local resp, err = mirq.mcp.call(cfg.mcp_endpoint, server, tool, args)
  if not resp then
    post_reply(evt, "MCP call failed: " .. tostring(err or "unknown error"))
    return true
  end

  local compact = trim(resp)
  if #compact > cfg.max_reply_chars then
    compact = compact:sub(1, cfg.max_reply_chars) .. "\n\n[truncated]"
  end
  post_reply(evt, "MCP result:\n" .. compact)
  return true
end

local function handle_command(evt, prompt)
  local cmd, rest = prompt:match("^([%w_-]+)%s*(.*)$")
  cmd = trim(cmd):lower()
  rest = trim(rest)

  if cmd == "" or cmd == "help" then
    post_reply(evt, cmd_help())
    return true
  end

  if cmd == "enable" then
    set_channel_enabled(evt, true)
    post_reply(evt, evt.is_dm and "Auto-assist is always enabled in DM." or "Assistant enabled for this channel.")
    return true
  end

  if cmd == "disable" then
    set_channel_enabled(evt, false)
    post_reply(evt, evt.is_dm and "DM auto-assist cannot be disabled." or "Assistant disabled for this channel.")
    return true
  end

  if cmd == "remember" then
    if rest == "" then
      post_reply(evt, "Usage: /ai remember <fact>")
    else
      mirq.memory.set(key_channel_fact(evt.guild_id, evt.channel_id, evt.author_id, evt.timestamp), rest)
      post_reply(evt, "Saved to channel memory.")
    end
    return true
  end

  if cmd == "profile" then
    local p = mirq.memory.get(key_member_profile(evt.guild_id, evt.author_id))
    if not p or trim(p) == "" then
      post_reply(evt, "No profile data yet. Talk with me and I will build one over time.")
    else
      post_reply(evt, "Current profile context:\n" .. p)
    end
    return true
  end

  if cmd == "skill" then
    return handle_skill_command(evt, rest)
  end

  if cmd == "mcp" then
    return handle_mcp_command(evt, rest)
  end

  return false
end

local function build_system_prompt(evt, prompt)
  local profile = mirq.memory.get(key_member_profile(evt.guild_id, evt.author_id)) or ""
  local history = load_history(evt.guild_id, evt.author_id)
  local rag = gather_rag_context(evt, prompt)
  local skills = relevant_skills(prompt)

  local chunks = {
    "You are a guild member assistant in MIRQ.",
    "Be helpful, concise, and friendly. Do not invent facts. Ask clarifying questions when needed.",
    "Respect guild context and tone. Keep replies practical.",
    "",
    "Member profile:",
    profile ~= "" and profile or "(none)",
    "",
    "Recent conversation with this member:",
    history ~= "" and history or "(none)",
    "",
    "Relevant channel memory (RAG):",
    rag ~= "" and rag or "(none)",
    "",
    "Relevant local skills:",
    skills ~= "" and skills or "(none)"
  }

  return table.concat(chunks, "\n")
end

function onLoad(ctx)
  mirq.log("lmstudio-assistant loaded: " .. tostring(ctx and ctx.plugin_id or "unknown"))
end

function onUnload()
  mirq.log("lmstudio-assistant unloaded")
end

function onMessageCreate(evt)
  if type(evt) ~= "table" or not evt.content then return end
  if evt.from_plugin then return end

  update_profile(evt)

  local direct = is_direct_trigger(evt.content, evt.is_dm)
  if not direct and not channel_enabled(evt) then
    return
  end

  local prompt = extract_prompt(evt.content)
  if prompt == "" then return end

  if starts_with_ci(trim(evt.content), cfg.command_prefix) then
    if handle_command(evt, prompt) then return end
  end

  append_history(evt.guild_id, evt.author_id, "user", prompt)

  local system_prompt = build_system_prompt(evt, prompt)
  local answer, err = lmstudio_chat(system_prompt, prompt)
  if not answer then
    post_reply(evt, "I couldn't reach LM Studio right now: " .. tostring(err or "unknown error"))
    return
  end

  append_history(evt.guild_id, evt.author_id, "assistant", answer)
  post_reply(evt, answer)
end
