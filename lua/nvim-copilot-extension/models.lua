local M = {}

local auth = require("nvim-copilot-extension.auth")

local cache = {
  models = nil,
  timestamp = 0,
}

local ttl_ms = 5 * 60 * 1000

local function now()
  return vim.loop.now()
end

local function supports_chat(model)
  return vim.tbl_contains(model.supported_endpoints or {}, "/chat/completions")
end

local function enabled(model)
  return model.model_picker_enabled ~= false and (not model.policy or model.policy.state ~= "disabled")
end

local function normalize(models)
  local filtered = vim.tbl_filter(function(model)
    return supports_chat(model) and enabled(model)
  end, models or {})

  local category_order = {
    versatile = 1,
    lightweight = 2,
    powerful = 3,
  }

  table.sort(filtered, function(a, b)
    if a.default and not b.default then
      return true
    end
    if b.default and not a.default then
      return false
    end
    local ac = category_order[a.model_picker_category or ""] or 99
    local bc = category_order[b.model_picker_category or ""] or 99
    if ac ~= bc then
      return ac < bc
    end
    return (a.name or a.modelName or a.id) < (b.name or b.modelName or b.id)
  end)

  return filtered
end

function M.list(_, cb)
  if cache.models and now() - cache.timestamp < ttl_ms then
    cb(normalize(cache.models))
    return
  end

  auth.get_token(function(token, err)
    if not token then
      cb(nil, err)
      return
    end

    vim.system({
      "curl",
      "-sS",
      "-H",
      "Authorization: Bearer " .. token,
      "-H",
      "Accept: application/json",
      "-H",
      "Editor-Version: Neovim/0.11.0",
      "-H",
      "Editor-Plugin-Version: nvim-copilot-extension/0.1.0",
      "-H",
      "Copilot-Integration-Id: vscode-chat",
      "https://api.githubcopilot.com/models",
    }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          cb(nil, result.stderr)
          return
        end

        local ok, decoded = pcall(vim.json.decode, result.stdout)
        if not ok or type(decoded) ~= "table" then
          cb(nil, "Invalid Copilot models response")
          return
        end

        if decoded.error then
          cb(nil, decoded.error.message or vim.json.encode(decoded.error))
          return
        end

        cache.models = decoded.data or {}
        cache.timestamp = now()
        cb(normalize(cache.models))
      end)
    end)
  end)
end

function M.cached_choices()
  return normalize(cache.models or {})
end

function M.resolve(selected, cb)
  if selected and selected ~= "" and selected ~= "default" then
    cb(selected)
    return
  end

  M.list("chat", function(models, err)
    if err then
      cb(nil, err)
      return
    end

    if not models or #models == 0 then
      cb(nil, "No Copilot chat models available")
      return
    end

    local default = vim.tbl_filter(function(model)
      return model.default
    end, models)[1]

    cb((default or models[1]).id)
  end)
end

function M.format(model)
  local label = model.name or model.modelName or model.id
  local suffix = {}
  if model.model_picker_category then
    table.insert(suffix, model.model_picker_category)
  end
  if model.default then
    table.insert(suffix, "default")
  end
  if model.preview then
    table.insert(suffix, "preview")
  end
  if #suffix > 0 then
    label = label .. " (" .. table.concat(suffix, ", ") .. ")"
  end
  return label .. " [" .. model.id .. "]"
end

return M
