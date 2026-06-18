local auth = require("nvim-copilot-extension.auth")
local diff = require("nvim-copilot-extension.diff")
local edit_review = require("nvim-copilot-extension.edit_review")
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

local function create_command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

function M.setup(cfg)
  create_command("CopilotPanelToggle", function()
    ui.toggle()
  end, {})

  create_command("CopilotPanelChat", function(opts)
    ui.send(opts.args)
  end, { nargs = "*" })

  create_command("CopilotPanelQuickPrompt", function()
    ui.quick_prompt()
  end, {})

  create_command("CopilotPanelNewChat", function()
    ui.new_chat()
  end, {})

  create_command("CopilotPanelChats", function()
    ui.select_chat()
  end, {})

  create_command("CopilotPanelDeleteChat", function()
    ui.delete_chat()
  end, {})

  create_command("CopilotPanelAcceptAllChanges", function()
    edit_review.accept_all()
  end, {})

  create_command("CopilotPanelAcceptAllChangesGlobal", function()
    edit_review.accept_all_global()
  end, {})

  create_command("CopilotPanelInlineEdit", function(opts)
    ui.inline_edit(opts)
  end, { range = true })

  create_command("CopilotPanelApplyLastDiff", function()
    diff.apply_last()
  end, {})

  create_command("CopilotPanelReviewLastDiff", function()
    diff.open_last_review()
  end, {})

  create_command("CopilotPanelAuth", function()
    auth.signin()
  end, {})

  create_command("CopilotPanelAuthInfo", function()
    auth.auth_info()
  end, {})

  create_command("CopilotPanelMode", function(opts)
    state.set_mode(opts.args)
  end, {
    nargs = 1,
    complete = function()
      return cfg.mode.choices
    end,
  })

  create_command("CopilotPanelSelectMode", function()
    state.select_mode()
  end, {})

  create_command("CopilotPanelAgent", function(opts)
    state.set_agent(opts.args)
    state.set_mode("agent")
  end, {
    nargs = 1,
    complete = function()
      return vim.tbl_keys(cfg.agent.profiles)
    end,
  })

  create_command("CopilotPanelSelectAgent", function()
    state.select_agent()
  end, {})

  create_command("CopilotPanelModel", function(opts)
    state.set_model(opts.args)
  end, {
    nargs = 1,
    complete = function()
      return vim.tbl_map(function(model)
        return model.id
      end, models.cached_choices("chat"))
    end,
  })

  create_command("CopilotPanelModels", function()
    models.list("chat", function(choices, err)
      if err then
        vim.notify("Failed to get Copilot Panel chat models: " .. err, vim.log.levels.ERROR)
        return
      end
      local lines = vim.tbl_map(models.format, choices or {})
      vim.notify(#lines > 0 and table.concat(lines, "\n") or "No Copilot chat models available")
    end)
  end, {})

  create_command("CopilotPanelTools", function()
    vim.notify(tools.describe())
  end, {})

  create_command("CopilotPanelSelectModel", function()
    state.select_model()
  end, {})

  create_command("CopilotPanelStatus", function()
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
          "CopilotPanel: %s; %s; mode=%s, model=%s, agent=%s",
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

  create_command("CopilotPanelUsage", function()
    auth.usage(function(text, err)
      if err then
        vim.notify("CopilotPanel usage failed: " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify(text, vim.log.levels.INFO)
    end)
  end, {})

  create_command("CopilotPanelStop", function()
    ui.stop_agent()
  end, {})

  map(cfg.keymaps.toggle_panel, ui.toggle, "CopilotPanel toggle panel")
  map(cfg.keymaps.select_model, state.select_model, "CopilotPanel select model")
  map(cfg.keymaps.select_mode, state.select_mode, "CopilotPanel select mode")
  map(cfg.keymaps.select_agent, state.select_agent, "CopilotPanel select agent")
  map(cfg.keymaps.select_chat, ui.select_chat, "CopilotPanel browse chats")
  map(cfg.keymaps.new_chat, ui.new_chat, "CopilotPanel new chat")
  map(cfg.keymaps.delete_chat, ui.delete_chat, "CopilotPanel delete chat")
  map(cfg.keymaps.accept_all_changes, edit_review.accept_all, "CopilotPanel accept all changes in file")
  map(cfg.keymaps.accept_all_changes_global, edit_review.accept_all_global, "CopilotPanel accept all changes in all files")
  map(cfg.keymaps.inline_edit, ui.inline_edit, "CopilotPanel inline edit", { "n", "v" })
  map(cfg.keymaps.quick_prompt, ui.quick_prompt, "CopilotPanel quick prompt")
  map(cfg.keymaps.stop_agent, ui.stop_agent, "CopilotPanel stop running agent")
end

return M
