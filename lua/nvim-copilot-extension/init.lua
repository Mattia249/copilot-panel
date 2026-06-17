local chats = require("nvim-copilot-extension.chats")
local config = require("nvim-copilot-extension.config")
local commands = require("nvim-copilot-extension.commands")
local state = require("nvim-copilot-extension.state")

local M = {}

function M.setup(opts)
  config.setup(opts)
  chats.setup(config.get())
  state.setup(config.get())
  commands.setup(config.get())
end

function M.toggle()
  require("nvim-copilot-extension.ui").toggle()
end

function M.chat(prompt)
  require("nvim-copilot-extension.ui").send(prompt)
end

function M.select_model()
  state.select_model()
end

function M.select_mode()
  state.select_mode()
end

function M.select_agent()
  state.select_agent()
end

return M
