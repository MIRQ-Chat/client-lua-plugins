local mirq = require('mirq')

local cfg = {
  command_prefix = "/otacon",
  transport_mode = "assist_sync", -- assist_sync | submit_async
  submit_url = "http://127.0.0.1:8787/mirq/submit", -- async queue + outbox
  assist_url = "http://127.0.0.1:8787/mirq/assist", -- synchronous direct response
  outbox_url = "http://127.0.0.1:8787/mirq/outbox",
  outbox_drain_url = "http://127.0.0.1:8787/mirq/outbox-drain",
  chunk_size = 1800,
  max_response_chars = 24000,
  tick_interval_ms = 500,
  pending_tick_interval_ms = 250,
  thinking_animation = true,
  thinking_animation_interval_ms = 700,
  thinking_frames = {
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏"
  },

  interaction_mode = "mention_or_command",
  dm_auto_respond = true,
  assistant_triggers = { "otacon", "@otacon", "openclaw", "@openclaw" },

  reply_target = nil,
  allowed_guild_ids = {},
  allowed_channel_ids = {},

  -- Guardrails and memory settings
  active_window_secs = 2 * 60 * 60,
  max_active_members_in_context = 8,
  max_channel_facts_in_context = 8,
  max_profile_chars = 1200,
  max_history_chars = 5000,

  -- Seed admins can bootstrap policy commands on first use.
  -- Example: { 12345, 67890 }
  seed_admin_user_ids = {}
}

local last_tick_check = 0
local next_request_id = 1
local indicatorByRequestId = {}         -- req_id -> {channel_id, message_id?, frame_idx, awaiting_response}
local pendingIndicatorByChannel = {}    -- channel_id(string) -> {req_id,...} awaiting message_id capture
local awaitingResponseByChannel = {}    -- channel_id(string) -> {req_id,...} FIFO response correlation

local function trim(s)
  return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(s)
  return trim(s):lower()
end

local function make_request_id()
  local id = tostring(next_request_id)
  next_request_id = next_request_id + 1
  return id
end

local function channel_key(channel_id)
  return tostring(tonumber(channel_id) or 0)
end

local function qpush(tbl, key, value)
  if not tbl[key] then tbl[key] = {} end
  tbl[key][#tbl[key] + 1] = value
end

local function qpop(tbl, key)
  local q = tbl[key]
  if not q or #q == 0 then return nil end
  local v = q[1]
  table.remove(q, 1)
  if #q == 0 then tbl[key] = nil end
  return v
end

local function qremove_value(tbl, key, value)
  local q = tbl[key]
  if not q then return end
  for i = #q, 1, -1 do
    if q[i] == value then
      table.remove(q, i)
    end
  end
  if #q == 0 then tbl[key] = nil end
end

local function current_indicator_frame(ind)
  local frames = cfg.thinking_frames or {}
  if #frames == 0 then return "…" end
  local idx = tonumber(ind.frame_idx) or 1
  if idx < 1 or idx > #frames then idx = 1 end
  return tostring(frames[idx])
end

local function in_set(value, set_tbl)
  if not set_tbl or #set_tbl == 0 then return true end
  for _, v in ipairs(set_tbl) do
    if tonumber(v) == tonumber(value) then return true end
  end
  return false
end

local function split_words(s)
  local out = {}
  for w in tostring(s or ""):lower():gmatch("[%w_]+") do
    out[#out + 1] = w
  end
  return out
end

local function to_bool_string(v)
  return v and "true" or "false"
end

local function json_escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local function now_seconds_from_evt(evt)
  local raw = tonumber(evt and evt.timestamp) or 0
  if raw > 1000000000000 then
    return math.floor(raw / 1000)
  end
  return math.floor(raw)
end

local function has_memory_api()
  return mirq and mirq.memory and mirq.memory.get and mirq.memory.set
end

local function mget(key)
  if not has_memory_api() then return nil end
  return mirq.memory.get(key)
end

local function mset(key, value)
  if not has_memory_api() then return false end
  return mirq.memory.set(key, value)
end

local function mdel(key)
  if not has_memory_api() then return false end
  return mirq.memory.del(key)
end

local function mkeys(prefix)
  if not has_memory_api() or not mirq.memory.keys then return {} end
  return mirq.memory.keys(prefix) or {}
end

local function msearch(query, limit)
  if not has_memory_api() or not mirq.memory.search then return {} end
  return mirq.memory.search(query, limit) or {}
end

local function key_policy_privacy()
  return "oc:policy:privacy_mode"
end

local function key_admin(guild_id, user_id)
  return string.format("oc:admin:g:%s:u:%s", tostring(guild_id or 0), tostring(user_id or 0))
end

local function key_member_state(guild_id, user_id)
  return string.format("oc:member:g:%s:u:%s", tostring(guild_id or 0), tostring(user_id or 0))
end

local function key_member_history(guild_id, user_id)
  return string.format("oc:history:g:%s:u:%s", tostring(guild_id or 0), tostring(user_id or 0))
end

local function key_member_profile(guild_id, user_id)
  return string.format("oc:profile:g:%s:u:%s", tostring(guild_id or 0), tostring(user_id or 0))
end

local function key_channel_fact(guild_id, channel_id, author_id, ts)
  return string.format("oc:fact:g:%s:c:%s:u:%s:t:%s", tostring(guild_id or 0), tostring(channel_id or 0), tostring(author_id or 0), tostring(ts or 0))
end

local function key_channel_mode(guild_id, channel_id)
  return string.format("oc:channel:g:%s:c:%s:enabled", tostring(guild_id or 0), tostring(channel_id or 0))
end

local function parse_state(raw)
  local out = {
    handle = "",
    last_seen = 0,
    msg_count = 0,
    dm_count = 0,
    trust = "normal"
  }
  raw = tostring(raw or "")
  if raw == "" then return out end
  for kv in raw:gmatch("[^|]+") do
    local k, v = kv:match("^([^=]+)=(.*)$")
    if k == "handle" then out.handle = v
    elseif k == "last_seen" then out.last_seen = tonumber(v) or 0
    elseif k == "msg_count" then out.msg_count = tonumber(v) or 0
    elseif k == "dm_count" then out.dm_count = tonumber(v) or 0
    elseif k == "trust" then out.trust = lower(v)
    end
  end
  if out.trust == "" then out.trust = "normal" end
  return out
end

local function encode_state(st)
  return table.concat({
    "handle=" .. trim(st.handle),
    "last_seen=" .. tostring(math.floor(tonumber(st.last_seen) or 0)),
    "msg_count=" .. tostring(math.floor(tonumber(st.msg_count) or 0)),
    "dm_count=" .. tostring(math.floor(tonumber(st.dm_count) or 0)),
    "trust=" .. lower(st.trust or "normal")
  }, "|")
end

local function load_member_state(guild_id, user_id)
  return parse_state(mget(key_member_state(guild_id, user_id)))
end

local function save_member_state(guild_id, user_id, st)
  mset(key_member_state(guild_id, user_id), encode_state(st))
end

local function get_privacy_mode()
  local mode = lower(mget(key_policy_privacy()) or "")
  if mode ~= "open" and mode ~= "balanced" and mode ~= "strict" then
    mode = "balanced"
  end
  return mode
end

local function is_admin(evt)
  if evt.is_dm then
    for _, id in ipairs(cfg.seed_admin_user_ids or {}) do
      if tonumber(id) == tonumber(evt.author_id) then return true end
    end
  end

  for _, id in ipairs(cfg.seed_admin_user_ids or {}) do
    if tonumber(id) == tonumber(evt.author_id) then return true end
  end

  return (mget(key_admin(evt.guild_id, evt.author_id)) or "0") == "1"
end

local function get_trust_level(evt)
  local st = load_member_state(evt.guild_id, evt.author_id)
  local t = st.trust
  if t == "" then t = "normal" end
  if t ~= "blocked" and t ~= "low" and t ~= "normal" and t ~= "high" then
    t = "normal"
  end
  if is_admin(evt) then
    return "high"
  end
  return t
end

local function set_trust_level(guild_id, user_id, trust)
  trust = lower(trust)
  if trust ~= "blocked" and trust ~= "low" and trust ~= "normal" and trust ~= "high" then
    return false
  end
  local st = load_member_state(guild_id, user_id)
  st.trust = trust
  save_member_state(guild_id, user_id, st)
  return true
end

local function channel_enabled(evt)
  if evt.is_dm then return true end
  return (mget(key_channel_mode(evt.guild_id, evt.channel_id)) or "1") == "1"
end

local function set_channel_enabled(evt, enabled)
  if evt.is_dm then return end
  mset(key_channel_mode(evt.guild_id, evt.channel_id), enabled and "1" or "0")
end

local function is_allowed_target(evt)
  if evt.is_dm then return true end
  return in_set(evt.guild_id, cfg.allowed_guild_ids) and in_set(evt.channel_id, cfg.allowed_channel_ids)
end

local function post_to_target(evt, text)
  if evt.is_dm then
    local tid = evt.thread_id or evt.channel_id
    mirq.dm.post(tid, text)
  elseif cfg.reply_target then
    mirq.chat.post(cfg.reply_target, text)
  else
    mirq.chat.post(evt.channel_id, text)
  end
end

local function split_chunks(text, max_len)
  local chunks = {}
  local i, n = 1, #text
  while i <= n do
    local j = math.min(i + max_len - 1, n)
    if j < n then
      local window = text:sub(i, j)
      local break_at = window:match(".*()%s")
      if break_at and break_at > math.floor(max_len * 0.5) then
        j = i + break_at - 1
      end
    end
    local part = trim(text:sub(i, j))
    if part ~= "" then chunks[#chunks + 1] = part end
    i = j + 1
  end
  return chunks
end

local function post_response(evt, text)
  local body = trim(text)
  if body == "" then
    post_to_target(evt, "Otacon bridge returned an empty response.")
    return
  end
  if #body > cfg.max_response_chars then
    body = body:sub(1, cfg.max_response_chars) .. "\n\n[truncated: response exceeded safe size]"
  end
  local parts = split_chunks(body, cfg.chunk_size)
  if #parts == 0 then
    post_to_target(evt, "Otacon bridge returned an empty response.")
    return
  end
  if #parts == 1 then
    post_to_target(evt, parts[1])
    return
  end
  for idx, part in ipairs(parts) do
    post_to_target(evt, string.format("(%d/%d) %s", idx, #parts, part))
  end
end

local function start_thinking_indicator(evt)
  if not cfg.thinking_animation then return nil end
  if evt.is_dm then return nil end
  if cfg.reply_target then return nil end
  if not mirq.chat or not mirq.chat.post then return nil end

  local req_id = make_request_id()
  local ch = tonumber(evt.channel_id) or 0
  if ch <= 0 then return nil end

  local can_update = mirq.chat and mirq.chat.update and true or false
  local ind = {
    request_id = req_id,
    channel_id = ch,
    message_id = 0,
    frame_idx = 1,
    last_anim_ms = 0,
    can_update = can_update,
    awaiting_response = true
  }
  indicatorByRequestId[req_id] = ind
  if can_update then
    qpush(pendingIndicatorByChannel, channel_key(ch), req_id)
  end
  qpush(awaitingResponseByChannel, channel_key(ch), req_id)
  mirq.chat.post(ch, current_indicator_frame(ind))
  return req_id
end

local function capture_indicator_message_id(evt)
  if not evt or not evt.from_plugin or evt.is_dm then return end
  local ch = tonumber(evt.channel_id) or 0
  local mid = tonumber(evt.message_id) or 0
  if ch <= 0 or mid <= 0 then return end

  local req_id = qpop(pendingIndicatorByChannel, channel_key(ch))
  if not req_id then return end
  local ind = indicatorByRequestId[req_id]
  if not ind then return end
  ind.message_id = mid
end

local function animate_indicators(now_ms)
  if not cfg.thinking_animation then return end
  local interval = tonumber(cfg.thinking_animation_interval_ms) or 700
  if interval < 200 then interval = 200 end

  for _, ind in pairs(indicatorByRequestId) do
    if ind.awaiting_response and ind.can_update and ind.message_id and ind.message_id > 0 then
      if now_ms - (tonumber(ind.last_anim_ms) or 0) >= interval then
        local frames = cfg.thinking_frames or {}
        if #frames > 0 then
          ind.frame_idx = (tonumber(ind.frame_idx) or 1) + 1
          if ind.frame_idx > #frames then ind.frame_idx = 1 end
        else
          ind.frame_idx = 1
        end
        local ok = pcall(function()
          mirq.chat.update(ind.channel_id, ind.message_id, current_indicator_frame(ind))
        end)
        if ok then
          ind.last_anim_ms = now_ms
        end
      end
    end
  end
end

local function finalize_indicator_with_reply(channel_id, reply_text)
  local ch = tonumber(channel_id) or 0
  if ch <= 0 then return false end

  local req_id = qpop(awaitingResponseByChannel, channel_key(ch))
  if not req_id then return false end
  local ind = indicatorByRequestId[req_id]
  if not ind then return false end
  ind.awaiting_response = false

  local body = trim(tostring(reply_text or ""))
  if body == "" then
    body = "Otacon bridge returned an empty response."
  end
  if #body > cfg.max_response_chars then
    body = body:sub(1, cfg.max_response_chars) .. "\n\n[truncated: response exceeded safe size]"
  end
  local parts = split_chunks(body, cfg.chunk_size)
  if #parts == 0 then parts = { body } end

  if ind.can_update and ind.message_id and ind.message_id > 0 and mirq.chat and mirq.chat.update then
    local first = parts[1] or body
    local ok = pcall(function()
      mirq.chat.update(ch, ind.message_id, first)
    end)
    if ok then
      for i = 2, #parts do
        mirq.chat.post(ch, parts[i])
      end
      indicatorByRequestId[req_id] = nil
      return true
    end
  end

  indicatorByRequestId[req_id] = nil
  return false
end

local function parse_prompt(content, is_dm)
  local mode = cfg.interaction_mode or "command_only"
  local text = trim(content)
  if text == "" then return nil end

  if is_dm and cfg.dm_auto_respond then
    local has_prefix = text:sub(1, #cfg.command_prefix) == cfg.command_prefix
    if has_prefix then
      local p = trim(text:sub(#cfg.command_prefix + 1))
      if p == "" then return "__USAGE__" end
      return p
    end
    return text
  end

  local has_prefix = text:sub(1, #cfg.command_prefix) == cfg.command_prefix
  if has_prefix then
    local p = trim(text:sub(#cfg.command_prefix + 1))
    if p == "" then return "__USAGE__" end
    return p
  end

  if mode == "command_only" then return nil end

  local lowered = text:lower()
  for _, t in ipairs(cfg.assistant_triggers or {}) do
    local trigger = lower(t)
    if trigger ~= "" and lowered:sub(1, #trigger) == trigger then
      local rest = trim(text:sub(#trigger + 1):gsub("^[,:%-]+", ""))
      if rest == "" then return "__USAGE__" end
      return rest
    end
  end

  if mode == "channel_auto" then return text end
  return nil
end

local function parse_command_parts(prompt)
  local cmd, rest = trim(prompt):match("^([%w_-]+)%s*(.*)$")
  return lower(cmd or ""), trim(rest or "")
end

local function append_history(guild_id, user_id, role, content)
  local line = string.format("%s: %s", role, trim(content))
  local key = key_member_history(guild_id, user_id)
  local prior = mget(key) or ""
  local nextv = prior == "" and line or (prior .. "\n" .. line)
  if #nextv > cfg.max_history_chars then
    nextv = nextv:sub(#nextv - cfg.max_history_chars + 1)
  end
  mset(key, nextv)
end

local function update_member_profile(evt)
  local key = key_member_profile(evt.guild_id, evt.author_id)
  local cur = mget(key) or ""
  local add = string.format("%s said: %s", tostring(evt.author_handle or "member"), trim(evt.content or ""))
  local nxt = cur == "" and add or (cur .. "\n" .. add)
  if #nxt > cfg.max_profile_chars then
    nxt = nxt:sub(#nxt - cfg.max_profile_chars + 1)
  end
  mset(key, nxt)
end

local function track_activity(evt)
  local st = load_member_state(evt.guild_id, evt.author_id)
  st.handle = tostring(evt.author_handle or st.handle or "")
  st.last_seen = now_seconds_from_evt(evt)
  st.msg_count = (tonumber(st.msg_count) or 0) + 1
  if evt.is_dm then
    st.dm_count = (tonumber(st.dm_count) or 0) + 1
  end
  if st.trust == "" then st.trust = "normal" end
  save_member_state(evt.guild_id, evt.author_id, st)
end

local function active_members_snapshot(evt)
  local prefix = string.format("oc:member:g:%s:u:", tostring(evt.guild_id or 0))
  local keys = mkeys(prefix)
  local now_s = now_seconds_from_evt(evt)
  local out = {}

  for _, key in ipairs(keys or {}) do
    local uid = key:match("oc:member:g:[^:]+:u:(%d+)$")
    if uid then
      local st = parse_state(mget(key))
      if st.last_seen > 0 and (now_s - st.last_seen) <= cfg.active_window_secs then
        out[#out + 1] = {
          user_id = tonumber(uid) or 0,
          handle = st.handle,
          last_seen = st.last_seen,
          msg_count = tonumber(st.msg_count) or 0,
          trust = st.trust
        }
      end
    end
  end

  table.sort(out, function(a, b)
    if a.last_seen == b.last_seen then
      return a.msg_count > b.msg_count
    end
    return a.last_seen > b.last_seen
  end)

  local top = {}
  for i = 1, math.min(#out, cfg.max_active_members_in_context) do
    top[#top + 1] = out[i]
  end
  return top
end

local function channel_facts_context(evt, prompt, trust)
  if evt.is_dm then return {} end

  local scope = string.format("oc:fact:g:%s:c:%s:", tostring(evt.guild_id or 0), tostring(evt.channel_id or 0))
  local hits = msearch(prompt, 24)
  local out = {}

  for _, h in ipairs(hits or {}) do
    local k = tostring(h.key or "")
    if k:sub(1, #scope) == scope then
      out[#out + 1] = tostring(h.value or "")
      if #out >= cfg.max_channel_facts_in_context then break end
    end
  end

  -- In strict mode and low-trust users, only include very small fact context.
  local mode = get_privacy_mode()
  if mode == "strict" and (trust == "low" or trust == "blocked") then
    local strict_out = {}
    if out[1] then strict_out[1] = out[1] end
    return strict_out
  end

  return out
end

local function sensitive_prompt_reason(prompt)
  local p = lower(prompt)
  local sensitive = {
    "export", "dump", "token", "secret", "private key", "password", "audit log",
    "admin only", "moderator", "ban list", "dm history", "ip address", "invoice",
    "salary", "personnel file", "incident report", "credential", "reset account"
  }
  for _, w in ipairs(sensitive) do
    if p:find(w, 1, true) then
      return "Request appears to involve sensitive or restricted information."
    end
  end
  return nil
end

local function can_forward_prompt(evt, prompt)
  local mode = get_privacy_mode()
  local trust = get_trust_level(evt)

  if trust == "blocked" then
    return false, "Your requests are currently restricted. Please contact a guild admin."
  end

  local reason = sensitive_prompt_reason(prompt)
  if not reason then return true, nil end

  if is_admin(evt) then return true, nil end
  if trust == "high" and mode ~= "strict" then return true, nil end

  return false, reason
end

local function guild_context_text(evt, prompt)
  local trust = get_trust_level(evt)
  local profile = mget(key_member_profile(evt.guild_id, evt.author_id)) or ""
  local history = mget(key_member_history(evt.guild_id, evt.author_id)) or ""
  local active = active_members_snapshot(evt)
  local facts = channel_facts_context(evt, prompt, trust)
  local mode = get_privacy_mode()

  local lines = {}
  lines[#lines + 1] = "MIRQ guild assistant context:"
  lines[#lines + 1] = string.format("- privacy_mode: %s", mode)
  lines[#lines + 1] = string.format("- requester_user_id: %s", tostring(evt.author_id or 0))
  lines[#lines + 1] = string.format("- requester_handle: %s", tostring(evt.author_handle or ""))
  lines[#lines + 1] = string.format("- requester_trust: %s", trust)
  lines[#lines + 1] = string.format("- requester_is_admin: %s", tostring(is_admin(evt)))
  lines[#lines + 1] = string.format("- guild_id: %s", tostring(evt.guild_id or 0))
  lines[#lines + 1] = string.format("- channel_id: %s", tostring(evt.channel_id or 0))

  lines[#lines + 1] = "- active_members_recent:"
  if #active == 0 then
    lines[#lines + 1] = "  - none"
  else
    for _, a in ipairs(active) do
      lines[#lines + 1] = string.format("  - %s (id=%s, trust=%s, msgs=%s)", a.handle ~= "" and a.handle or "unknown", tostring(a.user_id), tostring(a.trust), tostring(a.msg_count))
    end
  end

  lines[#lines + 1] = "- requester_profile_excerpt:"
  lines[#lines + 1] = profile ~= "" and profile or "  (none)"

  lines[#lines + 1] = "- requester_recent_history:"
  lines[#lines + 1] = history ~= "" and history or "  (none)"

  lines[#lines + 1] = "- relevant_channel_facts:"
  if #facts == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, f in ipairs(facts) do
      lines[#lines + 1] = "  - " .. tostring(f)
    end
  end

  lines[#lines + 1] = "- safety_directives:"
  lines[#lines + 1] = "  - Never reveal secrets, credentials, private logs, or admin-only data."
  lines[#lines + 1] = "  - Refuse requests that exceed requester trust or role."
  lines[#lines + 1] = "  - Ask clarifying questions before any risky action."
  lines[#lines + 1] = "  - Prioritize privacy-preserving, minimal-disclosure responses."

  return table.concat(lines, "\n")
end

local function record_channel_fact(evt, fact_text)
  if evt.is_dm then return end
  local ts = now_seconds_from_evt(evt)
  mset(key_channel_fact(evt.guild_id, evt.channel_id, evt.author_id, ts), trim(fact_text))
end

local function cmd_help()
  return table.concat({
    "Otacon / OpenClaw commands:",
    "/otacon help",
    "/otacon enable | /otacon disable",
    "/otacon privacy <strict|balanced|open> (admin)",
    "/otacon whoactive",
    "/otacon profile [user_id]",
    "/otacon remember <fact>",
    "/otacon admin add <user_id> | remove <user_id> | list (admin)",
    "/otacon trust set <user_id> <blocked|low|normal|high> (admin)",
    "Mention 'otacon' or '@openclaw' to chat."
  }, "\n")
end

local function handle_policy_commands(evt, cmd, rest)
  if cmd == "enable" then
    set_channel_enabled(evt, true)
    post_to_target(evt, evt.is_dm and "DM auto-assist is already enabled." or "Assistant enabled for this channel.")
    return true
  end

  if cmd == "disable" then
    set_channel_enabled(evt, false)
    post_to_target(evt, evt.is_dm and "DM auto-assist cannot be disabled." or "Assistant disabled for this channel.")
    return true
  end

  if cmd == "privacy" then
    if not is_admin(evt) then
      post_to_target(evt, "Only admins can change privacy mode.")
      return true
    end
    local mode = lower(rest)
    if mode ~= "strict" and mode ~= "balanced" and mode ~= "open" then
      post_to_target(evt, "Usage: /otacon privacy <strict|balanced|open>")
      return true
    end
    mset(key_policy_privacy(), mode)
    post_to_target(evt, "Privacy mode set to: " .. mode)
    return true
  end

  return false
end

local function handle_admin_commands(evt, cmd, rest)
  if cmd == "admin" then
    if not is_admin(evt) then
      post_to_target(evt, "Only admins can manage admin list.")
      return true
    end
    local action, uid = rest:match("^([%w_-]+)%s*(%d*)$")
    action = lower(action or "")
    uid = tonumber(uid)

    if action == "list" then
      local keys = mkeys(string.format("oc:admin:g:%s:u:", tostring(evt.guild_id or 0)))
      local ids = {}
      for _, k in ipairs(keys) do
        local id = k:match("oc:admin:g:[^:]+:u:(%d+)$")
        if id then ids[#ids + 1] = id end
      end
      if #ids == 0 then
        post_to_target(evt, "No explicit guild admins stored in plugin policy.")
      else
        post_to_target(evt, "Plugin admin IDs: " .. table.concat(ids, ", "))
      end
      return true
    end

    if not uid then
      post_to_target(evt, "Usage: /otacon admin add <user_id> | remove <user_id> | list")
      return true
    end

    if action == "add" then
      mset(key_admin(evt.guild_id, uid), "1")
      post_to_target(evt, "Added plugin admin: " .. tostring(uid))
      return true
    elseif action == "remove" then
      mdel(key_admin(evt.guild_id, uid))
      post_to_target(evt, "Removed plugin admin: " .. tostring(uid))
      return true
    end

    post_to_target(evt, "Usage: /otacon admin add <user_id> | remove <user_id> | list")
    return true
  end

  if cmd == "trust" then
    if not is_admin(evt) then
      post_to_target(evt, "Only admins can set trust levels.")
      return true
    end
    local action, uid_s, level = rest:match("^([%w_-]+)%s+(%d+)%s*([%w_-]*)$")
    action = lower(action or "")
    local uid = tonumber(uid_s)
    level = lower(level or "")

    if action ~= "set" or not uid or level == "" then
      post_to_target(evt, "Usage: /otacon trust set <user_id> <blocked|low|normal|high>")
      return true
    end

    if not set_trust_level(evt.guild_id, uid, level) then
      post_to_target(evt, "Invalid trust level. Use blocked|low|normal|high.")
      return true
    end

    post_to_target(evt, string.format("Trust for %s set to %s", tostring(uid), level))
    return true
  end

  return false
end

local function handle_info_commands(evt, cmd, rest)
  if cmd == "help" or cmd == "" then
    post_to_target(evt, cmd_help())
    return true
  end

  if cmd == "whereami" then
    if evt.is_dm then
      post_to_target(evt, string.format("DM thread_id=%s", tostring(evt.thread_id or evt.channel_id or 0)))
    else
      post_to_target(evt, string.format("guild_id=%s channel_id=%s", tostring(evt.guild_id or 0), tostring(evt.channel_id or 0)))
    end
    return true
  end

  if cmd == "remember" then
    if rest == "" then
      post_to_target(evt, "Usage: /otacon remember <fact>")
    else
      record_channel_fact(evt, rest)
      post_to_target(evt, "Stored as channel memory.")
    end
    return true
  end

  if cmd == "whoactive" then
    local active = active_members_snapshot(evt)
    if #active == 0 then
      post_to_target(evt, "No active member snapshot available yet.")
      return true
    end
    local lines = { "Recently active members:" }
    for _, a in ipairs(active) do
      lines[#lines + 1] = string.format("- %s (id=%s, trust=%s, msgs=%s)", a.handle ~= "" and a.handle or "unknown", tostring(a.user_id), tostring(a.trust), tostring(a.msg_count))
    end
    post_to_target(evt, table.concat(lines, "\n"))
    return true
  end

  if cmd == "profile" then
    local uid = tonumber(rest) or tonumber(evt.author_id)
    local st = load_member_state(evt.guild_id, uid)
    local profile = mget(key_member_profile(evt.guild_id, uid)) or ""
    if profile == "" then profile = "(none)" end
    local out = string.format(
      "Profile for %s:\n- handle: %s\n- trust: %s\n- msgs: %s\n- dms: %s\n- last_seen: %s\n- notes:\n%s",
      tostring(uid),
      st.handle ~= "" and st.handle or "unknown",
      st.trust,
      tostring(st.msg_count),
      tostring(st.dm_count),
      tostring(st.last_seen),
      profile
    )
    post_to_target(evt, out)
    return true
  end

  return false
end

local function handle_otacon_command(evt, prompt)
  local cmd, rest = parse_command_parts(prompt)
  if handle_info_commands(evt, cmd, rest) then return true end
  if handle_policy_commands(evt, cmd, rest) then return true end
  if handle_admin_commands(evt, cmd, rest) then return true end
  return false
end

local function json_unescape(s)
  s = tostring(s or "")
  s = s:gsub("\\\"", "\"")
  s = s:gsub("\\\\", "\\")
  s = s:gsub("\\n", "\n")
  s = s:gsub("\\r", "\r")
  s = s:gsub("\\t", "\t")
  return s
end

local function extract_json_string(entry, key)
  local marker = "\"" .. key .. "\""
  local p = entry:find(marker, 1, true)
  if not p then return nil end
  local i = p + #marker
  local colon = entry:find(":", i, true)
  if not colon then return nil end
  i = colon + 1
  while i <= #entry and entry:sub(i, i):match("%s") do i = i + 1 end
  if entry:sub(i, i) ~= "\"" then return nil end
  i = i + 1

  local out = {}
  local esc = false
  while i <= #entry do
    local c = entry:sub(i, i)
    if esc then
      out[#out + 1] = "\\" .. c
      esc = false
    elseif c == "\\" then
      esc = true
    elseif c == "\"" then
      return json_unescape(table.concat(out))
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  return nil
end

local function extract_json_int(entry, key)
  local v = entry:match("\"" .. key .. "\"%s*:%s*(%-?%d+)")
  if not v then return nil end
  return tonumber(v)
end

local function extract_json_bool(entry, key)
  local v = entry:match("\"" .. key .. "\"%s*:%s*(true|false)")
  if v == "true" then return true end
  if v == "false" then return false end
  return nil
end

local function extract_json_objects(array_text)
  local objs = {}
  local depth = 0
  local in_string = false
  local esc = false
  local start_idx = 0

  for i = 1, #array_text do
    local c = array_text:sub(i, i)
    if in_string then
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == "\"" then
        in_string = false
      end
    else
      if c == "\"" then
        in_string = true
      elseif c == "{" then
        if depth == 0 then start_idx = i end
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 and start_idx > 0 then
          objs[#objs + 1] = array_text:sub(start_idx, i)
          start_idx = 0
        end
      end
    end
  end
  return objs
end

local function parse_outbox_messages(resp)
  local text = trim(resp or "")
  if text == "" then return {} end
  local objects = extract_json_objects(text)
  if #objects > 0 then return objects end

  -- Support wrapped responses: {"messages":[...]} or {"items":[...]}
  local arr = text:match("\"messages\"%s*:%s*(%b[])")
  if not arr then
    arr = text:match("\"items\"%s*:%s*(%b[])")
  end
  if arr then
    return extract_json_objects(arr)
  end
  return {}
end

local function drain_outbox()
  local resp, err = mirq.http.post(cfg.outbox_drain_url, "[]")
  if not resp then
    resp, err = mirq.http.post(cfg.outbox_url, "[]")
  end
  if not resp then
    if err and tostring(err) ~= "" then
      mirq.log("otacon outbox error:", tostring(err))
    end
    return
  end

  local objects = parse_outbox_messages(resp)
  if #objects == 0 then
    local compact = trim(tostring(resp or "")):gsub("%s+", " ")
    if compact ~= "" and compact ~= "[]" and compact ~= "{}" then
      mirq.log("otacon outbox parse: no messages in response:", compact:sub(1, 180))
    end
  end
  for _, obj in ipairs(objects) do
    local msg = trim(extract_json_string(obj, "message") or "")
    if msg ~= "" then
      local is_dm = extract_json_bool(obj, "is_dm") == true
      local thread_id = extract_json_int(obj, "thread_id") or 0
      local channel_num = extract_json_int(obj, "channel") or extract_json_int(obj, "channel_id") or 0
      local channel_str = extract_json_string(obj, "channel") or ""
      if channel_num <= 0 and channel_str ~= "" then
        channel_num = tonumber(channel_str) or 0
      end

      local ok_post, post_err = pcall(function()
        if is_dm then
          local dm_target = thread_id > 0 and thread_id or channel_num
          if dm_target > 0 then
            mirq.dm.post(dm_target, msg)
          end
          return
        end

        if channel_num > 0 and finalize_indicator_with_reply(channel_num, msg) then
          return
        end

        if channel_num > 0 then
          mirq.chat.post(channel_num, msg)
        elseif channel_str ~= "" then
          mirq.chat.post(channel_str, msg)
        end
      end)
      if not ok_post then
        mirq.log("otacon outbox post error:", tostring(post_err))
      end
    end
  end
end

local function build_bridge_payload(evt, prompt)
  local trust = get_trust_level(evt)
  local thread_id = evt.thread_id or (evt.is_dm and evt.channel_id or 0)
  local context = guild_context_text(evt, prompt)

  local payload = string.format(
    '{"source":"mirq-plugin","integration":"MIRQ","assistant":"otacon-openclaw","visibility":"%s","multi_user":%s,"channel_id":%d,"guild_id":%d,"author_id":%d,"author_handle":"%s","prompt":"%s","is_dm":%s,"thread_id":%d,"requester_trust":"%s","requester_is_admin":%s,"privacy_mode":"%s","guild_context":"%s"}',
    evt.is_dm and "dm" or "shared-channel",
    evt.is_dm and "false" or "true",
    tonumber(evt.channel_id) or 0,
    tonumber(evt.guild_id) or 0,
    tonumber(evt.author_id) or 0,
    json_escape(evt.author_handle or ""),
    json_escape(prompt),
    to_bool_string(evt.is_dm),
    tonumber(thread_id) or 0,
    json_escape(trust),
    to_bool_string(is_admin(evt)),
    json_escape(get_privacy_mode()),
    json_escape(context)
  )

  return payload
end

function onLoad(ctx)
  mirq.log("otacon-assistant v0.4.0 loaded: " .. tostring(ctx and ctx.plugin_id or "unknown"))
  mirq.log("otacon-assistant: privacy=" .. get_privacy_mode())

  -- Seed admin IDs once per guild as they become active in events.
end

function onUnload()
  mirq.log("otacon-assistant unloaded")
end

function onTick(evt)
  if (cfg.transport_mode or "assist_sync") ~= "submit_async" then
    return
  end

  local now = tonumber(evt and evt.timestamp_ms) or 0
  if now <= 0 then
    local ts = tonumber(evt and evt.timestamp) or 0
    if ts > 1000000000000 then
      now = math.floor(ts)
    elseif ts > 0 then
      now = math.floor(ts * 1000)
    end
  end
  if now <= 0 then
    now = math.floor(os.clock() * 1000)
  end

  animate_indicators(now)
  if now <= last_tick_check then
    now = last_tick_check + 1
  end
  local has_pending = next(awaitingResponseByChannel) ~= nil
  local tick_interval = has_pending and (tonumber(cfg.pending_tick_interval_ms) or 500)
                                  or (tonumber(cfg.tick_interval_ms) or 10000)
  if tick_interval < 100 then tick_interval = 100 end
  if now - last_tick_check < tick_interval then return end
  last_tick_check = now
  drain_outbox()
end

function onMessageCreate(...)
  local evt = ...

  if type(evt) ~= "table" then
    local channel_id, guild_id, author_id, author_handle, content, timestamp = ...
    evt = {
      channel_id = tonumber(channel_id) or 0,
      guild_id = tonumber(guild_id) or 0,
      author_id = tonumber(author_id) or 0,
      author_handle = tostring(author_handle or ""),
      content = tostring(content or ""),
      timestamp = tonumber(timestamp) or 0,
      is_dm = false
    }
  end

  if not evt or not evt.content or not evt.channel_id then return end
  if evt.from_plugin then
    capture_indicator_message_id(evt)
    -- Keep draining while indicator/events are flowing only for async transport.
    if (cfg.transport_mode or "assist_sync") == "submit_async" then
      drain_outbox()
    end
    return
  end
  if not is_allowed_target(evt) then return end

  track_activity(evt)
  update_member_profile(evt)

  if (cfg.transport_mode or "assist_sync") == "submit_async" then
    drain_outbox()
  end

  local is_dm = evt.is_dm == true
  local prompt = parse_prompt(evt.content, is_dm)
  if not prompt then return end

  if prompt == "__USAGE__" then
    if is_dm then
      post_to_target(evt, "Send a message and I can help.")
    else
      post_to_target(evt, "Usage: /otacon <message> OR 'otacon <message>'")
    end
    return
  end

  if prompt:sub(1, #cfg.command_prefix) == cfg.command_prefix then
    prompt = trim(prompt:sub(#cfg.command_prefix + 1))
  end

  local cmd, _ = parse_command_parts(prompt)
  if cmd ~= "" and handle_otacon_command(evt, prompt) then
    return
  end

  if not channel_enabled(evt) and not is_dm then
    return
  end

  local ok_to_send, deny_reason = can_forward_prompt(evt, prompt)
  if not ok_to_send then
    post_to_target(evt, "I can’t help with that request right now. " .. tostring(deny_reason or "Restricted by policy."))
    return
  end

  append_history(evt.guild_id, evt.author_id, "user", prompt)
  local mode = cfg.transport_mode or "assist_sync"
  local indicator_request_id = nil
  if cfg.thinking_animation and not evt.is_dm and not cfg.reply_target then
    -- Always show a visible activity message, even when update API is unavailable.
    indicator_request_id = start_thinking_indicator(evt)
    if not indicator_request_id then
      post_to_target(evt, current_indicator_frame({ frame_idx = #cfg.thinking_frames }))
    end
  end

  local payload = build_bridge_payload(evt, prompt)
  if mode == "submit_async" then
    local resp, err = mirq.http.post(cfg.submit_url, payload)
    if not resp then
      if indicator_request_id and indicatorByRequestId[indicator_request_id] then
        local ind = indicatorByRequestId[indicator_request_id]
        if ind.message_id and ind.message_id > 0 then
          pcall(function()
            mirq.chat.update(ind.channel_id, ind.message_id, "⚠️ Could not reach Otacon bridge: " .. tostring(err or "unknown"))
          end)
        else
          post_to_target(evt, "⚠️ Could not reach Otacon bridge: " .. tostring(err or "unknown"))
        end
        ind.awaiting_response = false
        indicatorByRequestId[indicator_request_id] = nil
        qremove_value(awaitingResponseByChannel, channel_key(evt.channel_id), indicator_request_id)
        qremove_value(pendingIndicatorByChannel, channel_key(evt.channel_id), indicator_request_id)
      else
        post_to_target(evt, "⚠️ Could not reach Otacon bridge: " .. tostring(err or "unknown"))
      end
      return
    end
    -- Async mode: response arrives via outbox.
    return
  end

  -- Default sync mode: immediate response, no tick/outbox dependency.
  local resp, err = mirq.http.post(cfg.assist_url, payload)
  if not resp then
    post_to_target(evt, "⚠️ Could not reach Otacon bridge: " .. tostring(err or "unknown"))
    return
  end
  post_response(evt, tostring(resp or ""))
end
