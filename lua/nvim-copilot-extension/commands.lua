local auth = require("nvim-copilot-extension.auth")
local diff = require("nvim-copilot-extension.diff")
local models = require("nvim-copilot-extension.models")
local state = require("nvim-copilot-extension.state")
local tools = require("nvim-copilot-extension.tools")
local ui = require("nvim-copilot-extension.ui")

local M = {}

local function map(lhs, rhs, desc, mode)
  if not lhs or lhs == false or lhs == "" then
    return
  end
  vim.keymap.set(mode or "n", lhs, rhs, { desc = desc, silent = true })
end

function M.setup(cfg)
  vim.api.nvim_create_user_command("CopilotExtToggle", function()
    ui.toggle()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtChat", function(opts)
    ui.send(opts.args)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("CopilotExtQuickPrompt", function()
    ui.quick_prompt()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtInlineEdit", function(opts)
    ui.inline_edit(opts)
  end, { range = true })

  vim.api.nvim_create_user_command("CopilotExtApplyLastDiff", function()
    diff.apply_last()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtAuth", function()
    auth.signin()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtAuthInfo", function()
    auth.auth_info()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtMode", function(opts)
    state.set_mode(opts.args)
  end, {
    nargs = 1,
    complete = function()
      return cfg.mode.choices
    end,
  })

  vim.api.nvim_create_user_command("CopilotExtSelectMode", function()
    state.select_mode()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtAgent", function(opts)
    state.set_agent(opts.args)
    state.set_mode("agent")
  end, {
    nargs = 1,
    complete = function()
      return vim.tbl_keys(cfg.agent.profiles)
    end,
  })

  vim.api.nvim_create_user_command("CopilotExtSelectAgent", function()
    state.select_agent()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtModel", function(opts)
    state.set_model(opts.args)
  end, {
    nargs = 1,
    complete = function()
      return vim.tbl_map(function(model)
        return model.id
      end, models.cached_choices("chat"))
    end,
  })

  vim.api.nvim_create_user_command("CopilotExtModels", function()
    models.list("chat", function(choices, err)
      if err then
        vim.notify("Failed to get Copilot chat models: " .. err, vim.log.levels.ERROR)
        return
      end
      local lines = vim.tbl_map(models.format, choices or {})
      vim.notify(#lines > 0 and table.concat(lines, "\n") or "No Copilot chat models available")
    end)
  end, {})

  vim.api.nvim_create_user_command("CopilotExtTools", function()
    vim.notify(tools.describe())
  end, {})

  vim.api.nvim_create_user_command("CopilotExtSelectModel", function()
    state.select_model()
  end, {})

  vim.api.nvim_create_user_command("CopilotExtStatus", function()
    auth.status_details(function(details)
      local copilot = details.copilot or {}
      local copilot_state
      if copilot.authenticated then
        copilot_state = "Copilot signed in as " .. copilot.user
      elseif details.local_credentials then
        copilot_state = "Copilot local credentials found"
      elseif copilot.available then
        copilot_state = "Copilot not signed in" .. (copilot.status and (" (" .. copilot.status .. ")") or "")
      else
        copilot_state = "Copilot unavailable: " .. (copilot.error or "unknown")
      end

      local chat_state = details.chat_token and "chat token available"
        or ("chat token unavailable: " .. (details.chat_token_error or "unknown"))

      vim.notify(
        string.format(
          "CopilotExt: %s; %s; mode=%s, model=%s, agent=%s",
          copilot_state,
          chat_state,
          state.mode(),
          state.model(),
          state.agent()
        ),
        details.chat_token and vim.log.levels.INFO or vim.log.levels.WARN
      )
    end)
  end, {})

  map(cfg.keymaps.toggle_panel, ui.toggle, "CopilotExt toggle panel")
  map(cfg.keymaps.select_model, state.select_model, "CopilotExt select model")
  map(cfg.keymaps.select_mode, state.select_mode, "CopilotExt select mode")
  map(cfg.keymaps.select_agent, state.select_agent, "CopilotExt select agent")
  map(cfg.keymaps.inline_edit, ui.inline_edit, "CopilotExt inline edit", { "n", "v" })
  map(cfg.keymaps.quick_prompt, ui.quick_prompt, "CopilotExt quick prompt")
end

return M
