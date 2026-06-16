local M = {}

local cached = nil

local function has_command(name)
  return vim.fn.exists(":" .. name) == 2
end

local function env_token()
  local token = vim.env.GITHUB_COPILOT_TOKEN or vim.env.GH_COPILOT_TOKEN
  if token and token ~= "" then
    return token
  end
end

local function auth_db_path()
  local ok_auth, copilot_auth = pcall(require, "copilot.auth")
  if ok_auth and type(copilot_auth.find_config_path) == "function" then
    local ok_path, config_path = pcall(copilot_auth.find_config_path)
    if ok_path and config_path then
      return config_path .. "/github-copilot/auth.db"
    end
  end
  return vim.fn.expand("~/.config/github-copilot/auth.db")
end

function M.local_credentials()
  local path = auth_db_path()
  return vim.fn.filereadable(path) == 1, path
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if ok then
    return decoded
  end
end

local function find_oauth_token()
  local paths = {
    vim.fn.stdpath("config") .. "/github-copilot/hosts.json",
    vim.fn.stdpath("data") .. "/github-copilot/hosts.json",
    vim.fn.expand("~/.config/github-copilot/hosts.json"),
  }

  for _, path in ipairs(paths) do
    local hosts = read_json(path)
    if type(hosts) == "table" then
      for _, host in pairs(hosts) do
        if type(host) == "table" and host.oauth_token then
          return host.oauth_token
        end
      end
    end
  end
end

local function copilot_lua_token()
  local ok_auth, auth = pcall(require, "copilot.auth")
  if ok_auth and type(auth.get_token) == "function" then
    local ok_token, token = pcall(auth.get_token)
    if ok_token and type(token) == "string" and token ~= "" then
      return token
    end
  end

  local ok, client = pcall(require, "copilot.client")
  if not ok then
    return nil
  end

  local ok_client, instance = pcall(client.get)
  if not ok_client or type(instance) ~= "table" then
    return nil
  end

  if type(instance.token) == "string" then
    return instance.token
  end

  if type(instance.get_token) == "function" then
    local ok_token, token = pcall(instance.get_token, instance)
    if ok_token then
      return token
    end
  end
end

local function exchange_token(oauth_token, cb)
  vim.system({
    "curl",
    "-sS",
    "-H",
    "Authorization: token " .. oauth_token,
    "-H",
    "Accept: application/json",
    "https://api.github.com/copilot_internal/v2/token",
  }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        cb(nil, result.stderr)
      end)
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    vim.schedule(function()
      if ok and decoded and decoded.token then
        cached = {
          token = decoded.token,
          expires_at = decoded.expires_at or (os.time() + 300),
        }
        cb(cached.token)
      else
        cb(nil, "Unable to parse Copilot token response")
      end
    end)
  end)
end

local function read_auth_db_token(cb)
  local has_db, db = M.local_credentials()
  if not has_db then
    cb(nil, "No Copilot auth.db found")
    return
  end

  if vim.fn.executable("sqlite3") == 1 then
    vim.system({
      "sqlite3",
      "-batch",
      "-noheader",
      db,
      "SELECT CAST(token_ciphertext AS TEXT) FROM oauth_tokens ORDER BY last_used_at DESC LIMIT 1;",
    }, { text = true }, function(result)
      vim.schedule(function()
        local token = vim.trim(result.stdout or "")
        if result.code == 0 and token ~= "" then
          cb(token)
        else
          cb(nil, result.stderr ~= "" and result.stderr or "sqlite3 could not read Copilot auth.db")
        end
      end)
    end)
    return
  end

  if vim.fn.executable("python3") == 1 then
    local script = table.concat({
      "import sqlite3,sys",
      "con=sqlite3.connect(sys.argv[1])",
      "row=con.execute('select token_ciphertext from oauth_tokens order by last_used_at desc limit 1').fetchone()",
      "sys.stdout.write((row[0].decode() if isinstance(row[0], bytes) else str(row[0])) if row else '')",
    }, ";")

    vim.system({ "python3", "-c", script, db }, { text = true }, function(result)
      vim.schedule(function()
        local token = vim.trim(result.stdout or "")
        if result.code == 0 and token ~= "" then
          cb(token)
        else
          cb(nil, result.stderr ~= "" and result.stderr or "python3 could not read Copilot auth.db")
        end
      end)
    end)
    return
  end

  cb(nil, "Reading Copilot auth.db requires sqlite3 or python3")
end

local function with_copilot_client(cb)
  local ok_client, client = pcall(require, "copilot.client")
  local ok_api, api = pcall(require, "copilot.api")
  if not ok_client or not ok_api then
    cb(nil, "copilot.lua is not loaded")
    return
  end

  local lsp_client = client.get and client.get()
  if lsp_client then
    cb({ client = lsp_client, api = api })
    return
  end

  if client.ensure_client_started then
    pcall(client.ensure_client_started)
  end

  local waited = 0
  local function poll()
    local current = client.get and client.get()
    if current then
      cb({ client = current, api = api })
      return
    end
    waited = waited + 100
    if waited >= 3000 then
      cb(nil, "Copilot LSP client is not available yet")
      return
    end
    vim.defer_fn(poll, 100)
  end
  poll()
end

function M.copilot_status(cb)
  with_copilot_client(function(ctx, err)
    if not ctx then
      cb({ available = false, authenticated = false, error = err })
      return
    end

    ctx.api.check_status(ctx.client, {}, function(status_err, status)
      vim.schedule(function()
        cb({
          available = true,
          authenticated = not status_err and status and status.user ~= nil,
          user = status and status.user or nil,
          status = status and status.status or nil,
          error = status_err,
        })
      end)
    end)
  end)
end

function M.signin()
  if has_command("Copilot") then
    vim.cmd("Copilot auth signin")
    return true
  end
  vim.notify("Copilot command not found. Install/configure copilot.lua first.", vim.log.levels.ERROR)
  return false
end

function M.auth_info()
  if has_command("Copilot") then
    vim.cmd("Copilot auth info")
    return true
  end
  vim.notify("Copilot command not found. Install/configure copilot.lua first.", vim.log.levels.ERROR)
  return false
end

function M.get_token(cb)
  if cached and cached.expires_at and cached.expires_at > os.time() + 30 then
    cb(cached.token)
    return
  end

  local from_env = env_token()
  if from_env then
    cached = { token = from_env, expires_at = os.time() + 300 }
    cb(from_env)
    return
  end

  local direct = copilot_lua_token()
  if direct then
    cached = { token = direct, expires_at = os.time() + 300 }
    cb(direct)
    return
  end

  local has_db = M.local_credentials()
  if has_db then
    read_auth_db_token(function(db_token, db_err)
      if not db_token then
        cb(nil, db_err)
        return
      end
      exchange_token(db_token, cb)
    end)
    return
  end

  local oauth = find_oauth_token()
  if not oauth then
    cb(nil, "No Copilot credentials found. Run :CopilotExtAuth first.")
    return
  end

  exchange_token(oauth, cb)
end

function M.status(cb)
  M.get_token(function(token, err)
    cb(token ~= nil, err)
  end)
end

function M.status_details(cb)
  local details = {
    chat_token = false,
    chat_token_error = nil,
    copilot = nil,
    local_credentials = false,
    local_credentials_path = nil,
  }

  details.local_credentials, details.local_credentials_path = M.local_credentials()

  M.get_token(function(token, err)
    details.chat_token = token ~= nil
    details.chat_token_error = err

    M.copilot_status(function(status)
      details.copilot = status
      cb(details)
    end)
  end)
end

return M
