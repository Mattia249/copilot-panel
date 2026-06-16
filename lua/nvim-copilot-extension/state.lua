local M = {}

local models = require("nvim-copilot-extension.models")

local cfg
local state = {
  model = "default",
  mode = "chat",
  agent = "implementer",
}

local function state_path()
  return vim.fn.stdpath("state") .. "/nvim-copilot-extension/state.json"
end

local function load()
  local path = state_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

local function save()
  if not cfg.model.persist and not cfg.mode.persist then
    return
  end

  local path = state_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(state) }, path)
end

local function valid(values, value)
  return vim.tbl_contains(values, value)
end

function M.setup(options)
  cfg = options
  local persisted = load()
  state.model = persisted.model or cfg.model.default
  state.mode = persisted.mode or cfg.mode.default
  state.agent = persisted.agent or cfg.agent.default

  if not valid(cfg.model.choices, state.model) then
    state.model = cfg.model.default
  end
  if not valid(cfg.mode.choices, state.mode) then
    state.mode = cfg.mode.default
  end
  if not cfg.agent.profiles[state.agent] then
    state.agent = cfg.agent.default
  end
end

function M.get()
  return vim.deepcopy(state)
end

function M.model()
  return state.model
end

function M.mode()
  return state.mode
end

function M.agent()
  return state.agent
end

function M.set_model(model)
  if model == nil or model == "" then
    return
  end
  state.model = model
  save()
  vim.api.nvim_exec_autocmds("User", { pattern = "CopilotExtStateChanged" })
  vim.notify("CopilotExt model: " .. model, vim.log.levels.INFO)
end

function M.set_mode(mode)
  if not valid(cfg.mode.choices, mode) then
    vim.notify("Invalid CopilotExt mode: " .. tostring(mode), vim.log.levels.ERROR)
    return
  end
  state.mode = mode
  save()
  vim.api.nvim_exec_autocmds("User", { pattern = "CopilotExtStateChanged" })
  vim.notify("CopilotExt mode: " .. mode, vim.log.levels.INFO)
end

function M.set_agent(agent)
  if not cfg.agent.profiles[agent] then
    vim.notify("Invalid CopilotExt agent: " .. tostring(agent), vim.log.levels.ERROR)
    return
  end
  state.agent = agent
  save()
  vim.api.nvim_exec_autocmds("User", { pattern = "CopilotExtStateChanged" })
  vim.notify("CopilotExt agent: " .. agent, vim.log.levels.INFO)
end

function M.select_model()
  models.list("chat", function(choices, err)
    if err then
      vim.notify("Failed to get Copilot chat models: " .. err, vim.log.levels.ERROR)
      return
    end

    if not choices or #choices == 0 then
      vim.notify("No Copilot chat models available", vim.log.levels.WARN)
      return
    end

    vim.ui.select(choices, {
    prompt = "Copilot model",
    format_item = function(item)
        local label = models.format(item)
        return item.id == state.model and (label .. "  current") or label
    end,
  }, function(choice)
    if choice then
        M.set_model(choice.id)
    end
  end)
  end)
end

function M.select_mode()
  vim.ui.select(cfg.mode.choices, {
    prompt = "Copilot mode",
    format_item = function(item)
      return item == state.mode and (item .. "  current") or item
    end,
  }, function(choice)
    if choice then
      M.set_mode(choice)
    end
  end)
end

function M.select_agent()
  local names = vim.tbl_keys(cfg.agent.profiles)
  table.sort(names)
  vim.ui.select(names, {
    prompt = "Copilot agent",
    format_item = function(item)
      local suffix = item == state.agent and "  current" or ""
      return item .. suffix
    end,
  }, function(choice)
    if choice then
      M.set_agent(choice)
      M.set_mode("agent")
    end
  end)
end

return M
