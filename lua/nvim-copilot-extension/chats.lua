local M = {}

local cfg = {
  persist = true,
  max_sessions = 50,
}

local store = {
  current_id = nil,
  sessions = {},
}

local function chats_path()
  return vim.fn.stdpath("state") .. "/nvim-copilot-extension/chats.json"
end

local function now()
  return os.time()
end

local function make_id()
  local random = tostring(math.random(1000, 9999))
  return tostring(now()) .. "-" .. random
end

local function summarize(text)
  local line = vim.split(text or "", "\n", { plain = true })[1] or ""
  line = vim.trim(line:gsub("#file:[^%s]+", ""):gsub("#%w+", ""))
  if line == "" then
    line = "New chat"
  end
  if #line > 60 then
    line = line:sub(1, 57) .. "..."
  end
  return line
end

local function default_session()
  local timestamp = now()
  return {
    id = make_id(),
    title = "New chat",
    created_at = timestamp,
    updated_at = timestamp,
    next_id = 1,
    messages = {},
  }
end

local function normalize_session(session)
  local normalized = vim.tbl_extend("force", default_session(), session or {})
  normalized.messages = normalized.messages or {}
  normalized.next_id = tonumber(normalized.next_id) or 1
  normalized.created_at = tonumber(normalized.created_at) or now()
  normalized.updated_at = tonumber(normalized.updated_at) or normalized.created_at

  if normalized.title == nil or normalized.title == "" or normalized.title == "New chat" then
    for _, message in ipairs(normalized.messages) do
      if message.kind == "user" and message.content and message.content ~= "" then
        normalized.title = summarize(message.content)
        break
      end
    end
  end

  return normalized
end

local function sort_sessions()
  table.sort(store.sessions, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
end

local function find_index(id)
  for index, session in ipairs(store.sessions) do
    if session.id == id then
      return index, session
    end
  end
end

local function current_session()
  local _, session = find_index(store.current_id)
  return session
end

local function ensure_current()
  local session = current_session()
  if session then
    return session
  end

  session = default_session()
  table.insert(store.sessions, session)
  store.current_id = session.id
  return session
end

local function save()
  if not cfg.persist then
    return
  end

  sort_sessions()
  while #store.sessions > (cfg.max_sessions or 50) do
    table.remove(store.sessions)
  end

  local path = chats_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(store) }, path)
end

local function load()
  local path = chats_path()
  if vim.fn.filereadable(path) ~= 1 then
    ensure_current()
    return
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    ensure_current()
    return
  end

  store.current_id = decoded.current_id
  store.sessions = {}
  for _, session in ipairs(decoded.sessions or {}) do
    table.insert(store.sessions, normalize_session(session))
  end

  if #store.sessions == 0 then
    ensure_current()
  else
    ensure_current()
    sort_sessions()
  end
end

function M.setup(options)
  cfg = vim.tbl_extend("force", cfg, options.chat or {})
  math.randomseed(now())
  load()
end

function M.current()
  return vim.deepcopy(ensure_current())
end

function M.list()
  sort_sessions()
  return vim.deepcopy(store.sessions)
end

function M.save_current(session)
  if not session or not session.id then
    return
  end

  session = normalize_session(session)
  session.updated_at = now()
  if session.title == nil or session.title == "" or session.title == "New chat" then
    for _, message in ipairs(session.messages or {}) do
      if message.kind == "user" and message.content and message.content ~= "" then
        session.title = summarize(message.content)
        break
      end
    end
  else
    session.title = summarize(session.title)
  end

  local index = find_index(session.id)
  if index then
    store.sessions[index] = session
  else
    table.insert(store.sessions, session)
  end
  store.current_id = session.id
  save()
end

function M.new_session()
  local session = default_session()
  table.insert(store.sessions, 1, session)
  store.current_id = session.id
  save()
  return vim.deepcopy(session)
end

function M.switch(id)
  local _, session = find_index(id)
  if not session then
    return nil
  end
  store.current_id = id
  save()
  return vim.deepcopy(session)
end

function M.delete(id)
  local index = find_index(id)
  if not index then
    return nil
  end

  table.remove(store.sessions, index)

  if #store.sessions == 0 then
    local session = default_session()
    table.insert(store.sessions, session)
    store.current_id = session.id
    save()
    return vim.deepcopy(session)
  end

  if store.current_id == id then
    sort_sessions()
    store.current_id = store.sessions[1].id
  end

  save()
  return vim.deepcopy(current_session() or store.sessions[1])
end

function M.current_id()
  return ensure_current().id
end

function M.format(session)
  local title = session.title or "New chat"
  local stamp = os.date("%Y-%m-%d %H:%M", session.updated_at or now())
  return string.format("%s  (%s)", title, stamp)
end

return M
