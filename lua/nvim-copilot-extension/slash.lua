local state = require("nvim-copilot-extension.state")

local M = {}

local prompts = {
  explain = "Explain the selected code or current buffer clearly.",
  fix = "Find and fix bugs. Return a concise explanation and a patch when appropriate.",
  tests = "Generate useful tests for the selected code or current buffer.",
  doc = "Write or improve documentation for the selected code.",
  refactor = "Refactor the selected code while preserving behavior.",
  commit = "Write a conventional commit message for the current changes.",
}

function M.expand(prompt)
  local command, rest = prompt:match("^%s*/([%w_-]+)%s*(.*)$")
  if not command then
    return prompt, nil
  end

  if command == "clear" then
    return nil, { action = "clear" }
  end

  if command == "model" then
    if rest ~= "" then
      state.set_model(rest)
    else
      state.select_model()
    end
    return nil, { action = "handled" }
  end

  if command == "mode" or command == "agent" then
    if command == "agent" then
      if rest ~= "" then
        state.set_agent(rest)
      else
        state.select_agent()
      end
      state.set_mode("agent")
    elseif rest ~= "" then
      state.set_mode(rest)
    else
      state.select_mode()
    end
    return nil, { action = "handled" }
  end

  local prefix = prompts[command]
  if prefix then
    return prefix .. "\n\n" .. rest, { command = command }
  end

  return prompt, nil
end

return M
