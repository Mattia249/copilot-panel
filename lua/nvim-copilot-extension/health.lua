local auth = require("nvim-copilot-extension.auth")
local state = require("nvim-copilot-extension.state")

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error = health.error or health.report_error
local info = health.info or health.report_info

function M.check()
  start("nvim-copilot-extension")

  if vim.fn.executable("curl") == 1 then
    ok("curl is available")
  else
    error("curl is required for Copilot API requests")
  end

  if vim.fn.exists(":Copilot") == 2 then
    ok(":Copilot command found")
  else
    warn(":Copilot command not found; install/configure copilot.lua or github/copilot.vim through LazyVim")
  end

  info("mode=" .. state.mode() .. ", model=" .. state.model() .. ", agent=" .. state.agent())

  auth.status(function(is_authenticated, err)
    if is_authenticated then
      ok("Copilot authentication token is available")
    else
      warn(err or "Copilot authentication token is not available")
    end
  end)
end

return M

