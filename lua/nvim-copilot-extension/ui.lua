local agent = require("nvim-copilot-extension.agent")
local client = require("nvim-copilot-extension.client")
local config = require("nvim-copilot-extension.config")
local context = require("nvim-copilot-extension.context")
local diff = require("nvim-copilot-extension.diff")
local slash = require("nvim-copilot-extension.slash")
local state = require("nvim-copilot-extension.state")
local tools = require("nvim-copilot-extension.tools")

local M = {}

local panel = {
  buf = nil,
  win = nil,
  messages = {},
  next_id = 1,
  layout = {
    input_start = nil,
    message_ranges = {},
  },
  composer = {
    editing_id = nil,
  },
  active_assistant_id = nil,
}

local input_placeholder = "Type a message. Press <Enter> to send."
local rule = string.rep("-", 40)
local guarded = false
local ns = vim.api.nvim_create_namespace("copilot-extension")

local function add_hl(name, opts)
  vim.api.nvim_set_hl(0, name, opts)
end

local function setup_highlights()
  add_hl("CopilotExtTitle", { link = "Title" })
  add_hl("CopilotExtMeta", { link = "Comment" })
  add_hl("CopilotExtUser", { link = "Identifier" })
  add_hl("CopilotExtAssistant", { link = "Function" })
  add_hl("CopilotExtTool", { link = "Special" })
  add_hl("CopilotExtToolResult", { link = "String" })
  add_hl("CopilotExtError", { link = "DiagnosticError" })
  add_hl("CopilotExtRule", { link = "WinSeparator" })
  add_hl("CopilotExtHint", { italic = true, fg = "#7d8590" })
end

local function header_lines()
  return {
    "Copilot Extension",
    "",
    "Mode: " .. state.mode() .. "    Model: " .. state.model() .. "    Agent: " .. state.agent(),
    "",
  }
end

local function next_id()
  local id = panel.next_id
  panel.next_id = panel.next_id + 1
  return id
end

local function add_message(kind, opts)
  local message = vim.tbl_extend("force", {
    id = next_id(),
    kind = kind,
    content = "",
    meta = {},
  }, opts or {})
  table.insert(panel.messages, message)
  return message
end

local function find_message_index(id)
  for index, message in ipairs(panel.messages) do
    if message.id == id then
      return index, message
    end
  end
end

local function get_message(id)
  local _, message = find_message_index(id)
  return message
end

local function message_for_line(line)
  for _, range in ipairs(panel.layout.message_ranges) do
    if line >= range.start_line and line <= range.end_line then
      return range.message
    end
  end
end

local function current_input_lines()
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) or not panel.layout.input_start then
    return { "" }
  end
  local lines = vim.api.nvim_buf_get_lines(panel.buf, panel.layout.input_start - 1, -1, false)
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function current_input_text()
  local lines = current_input_lines()
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

local function set_input_lines(lines)
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) or not panel.layout.input_start then
    return
  end
  guarded = true
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, panel.layout.input_start - 1, -1, false, lines)
  vim.bo[panel.buf].modified = false
  guarded = false
end

local function composer_label()
  if panel.composer.editing_id then
    return "Prompt [editing previous message]"
  end
  return "Prompt"
end

local function focus_input(startinsert)
  if not panel.win or not vim.api.nvim_win_is_valid(panel.win) or not panel.layout.input_start then
    return
  end

  local ok_win = pcall(vim.api.nvim_set_current_win, panel.win)
  if not ok_win then
    return
  end

  local input = current_input_lines()
  local line_count = vim.api.nvim_buf_line_count(panel.buf)
  if line_count < 1 then
    return
  end

  local target_row = panel.layout.input_start + math.max(#input - 1, 0)
  target_row = math.max(1, math.min(target_row, line_count))

  local line = vim.api.nvim_buf_get_lines(panel.buf, target_row - 1, target_row, false)[1] or ""
  local col = math.max(0, math.min(#(input[#input] or ""), #line))
  pcall(vim.api.nvim_win_set_cursor, panel.win, { target_row, col })
  if startinsert then
    vim.cmd("startinsert")
  end
end

local function conversation_messages(upto_id)
  local messages = {}
  for _, message in ipairs(panel.messages) do
    if upto_id and message.id == upto_id then
      if message.kind == "user" or message.kind == "assistant" then
        table.insert(messages, {
          role = message.kind,
          content = message.content,
        })
      end
      break
    end

    if message.kind == "user" or message.kind == "assistant" then
      table.insert(messages, {
        role = message.kind,
        content = message.content,
      })
    end
  end
  return messages
end

local function trim_after_message(message_id)
  local index = find_message_index(message_id)
  if not index then
    return
  end
  while #panel.messages > index do
    table.remove(panel.messages)
  end
end

local function expected_lines(input_lines)
  local lines = vim.list_extend(header_lines(), { rule })
  local ranges = {}
  local line_no = #lines + 1

  for _, message in ipairs(panel.messages) do
    local start_line = line_no
    table.insert(lines, "")
    line_no = line_no + 1

    if message.kind == "user" then
      table.insert(lines, "You")
      line_no = line_no + 1
      table.insert(lines, "")
      line_no = line_no + 1
      for _, line in ipairs(vim.split(message.content or "", "\n", { plain = true })) do
        table.insert(lines, line)
        line_no = line_no + 1
      end
    elseif message.kind == "assistant" then
      table.insert(lines, "Copilot")
      line_no = line_no + 1
      table.insert(lines, "")
      line_no = line_no + 1
      local content = message.content
      if content == "" and message.meta and message.meta.pending then
        content = "Working..."
      end
      for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
        table.insert(lines, line)
        line_no = line_no + 1
      end
    elseif message.kind == "tool_call" or message.kind == "tool_result" then
      for _, line in ipairs(vim.split(message.content or "", "\n", { plain = true })) do
        table.insert(lines, line)
        line_no = line_no + 1
      end
    elseif message.kind == "error" or message.kind == "system_note" then
      local title = message.kind == "error" and "Error" or "Note"
      table.insert(lines, title)
      line_no = line_no + 1
      table.insert(lines, "")
      line_no = line_no + 1
      for _, line in ipairs(vim.split(message.content or "", "\n", { plain = true })) do
        table.insert(lines, line)
        line_no = line_no + 1
      end
    end

    table.insert(ranges, {
      message = message,
      start_line = start_line,
      end_line = line_no - 1,
    })
  end

  table.insert(lines, "")
  table.insert(lines, rule)
  table.insert(lines, composer_label())
  local input_start = #lines + 1
  for _, line in ipairs(input_lines) do
    table.insert(lines, line)
  end

  return lines, {
    message_ranges = ranges,
    input_start = input_start,
  }
end

local function decorate()
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(panel.buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local zero = row - 1
    if row == 1 then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtTitle", zero, 0, -1)
    elseif line:match("^Mode:") then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtMeta", zero, 0, -1)
    elseif line == rule then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtRule", zero, 0, -1)
    elseif line == "You" then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtUser", zero, 0, -1)
    elseif line == "Copilot" then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtAssistant", zero, 0, -1)
    elseif line == "Error" then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtError", zero, 0, -1)
    elseif line == "Note" or line == composer_label() then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtMeta", zero, 0, -1)
    end
  end

  for _, range in ipairs(panel.layout.message_ranges) do
    if range.message.kind == "tool_call" then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtTool", range.start_line, 0, -1)
    elseif range.message.kind == "tool_result" then
      vim.api.nvim_buf_add_highlight(panel.buf, ns, "CopilotExtToolResult", range.start_line, 0, -1)
    end
  end

  if panel.layout.input_start then
    local input = current_input_lines()
    if #input == 1 and input[1] == "" then
      vim.api.nvim_buf_set_extmark(panel.buf, ns, panel.layout.input_start - 1, 0, {
        virt_text = { { input_placeholder, "CopilotExtHint" } },
        virt_text_pos = "overlay",
      })
    end
  end

  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    local cursor = vim.api.nvim_win_get_cursor(panel.win)
    local message = message_for_line(cursor[1])
    if message and message.kind == "user" then
      for _, range in ipairs(panel.layout.message_ranges) do
        if range.message.id == message.id then
          vim.api.nvim_buf_set_extmark(panel.buf, ns, range.start_line, 0, {
            virt_text = { { " [e edit and resend]", "CopilotExtHint" } },
            virt_text_pos = "eol",
          })
          break
        end
      end
    end
  end
end

local function render(opts)
  opts = opts or {}
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end

  local input_lines = opts.input_lines or current_input_lines()
  local cursor = nil
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    cursor = vim.api.nvim_win_get_cursor(panel.win)
  end

  local lines, layout = expected_lines(input_lines)
  guarded = true
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modified = false
  panel.layout = layout
  guarded = false
  decorate()

  if cursor and panel.win and vim.api.nvim_win_is_valid(panel.win) then
    local row = math.max(1, math.min(cursor[1], vim.api.nvim_buf_line_count(panel.buf)))
    local line = vim.api.nvim_buf_get_lines(panel.buf, row - 1, row, false)[1] or ""
    local col = math.max(0, math.min(cursor[2], #line))
    vim.api.nvim_win_set_cursor(panel.win, { row, col })
  end
end

local function protect_input()
  if guarded or not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end

  if not panel.layout.input_start then
    render()
    return
  end

  local input = current_input_lines()
  local expected, _ = expected_lines(input)
  local actual = vim.api.nvim_buf_get_lines(panel.buf, 0, panel.layout.input_start - 1, false)
  local expected_prefix = {}
  for i = 1, panel.layout.input_start - 1 do
    expected_prefix[i] = expected[i]
  end

  if vim.deep_equal(expected_prefix, actual) then
    decorate()
    return
  end

  render({ input_lines = input })
  focus_input(false)
end

local function update_message_content(id, content, meta)
  local message = get_message(id)
  if not message then
    return
  end
  message.content = content or ""
  if meta then
    message.meta = vim.tbl_extend("force", message.meta or {}, meta)
  end
  render()
end

local function append_message(kind, opts)
  local message = add_message(kind, opts)
  render()
  return message
end

local function start_assistant_message(meta)
  local message = append_message("assistant", {
    content = "",
    meta = vim.tbl_extend("force", { pending = true }, meta or {}),
  })
  panel.active_assistant_id = message.id
  return message
end

local function update_active_assistant(content)
  if not panel.active_assistant_id then
    return
  end
  update_message_content(panel.active_assistant_id, content, { pending = false })
end

local function finish_active_assistant(content)
  if not panel.active_assistant_id then
    return
  end
  update_message_content(panel.active_assistant_id, content or "", { pending = false })
  panel.active_assistant_id = nil
end

local function ensure_panel()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    return
  end

  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    setup_highlights()
    panel.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[panel.buf].filetype = "copilotext"
    vim.bo[panel.buf].buftype = "nofile"
    vim.bo[panel.buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(panel.buf, "Copilot Extension")

    vim.keymap.set({ "n", "i" }, "<CR>", function()
      require("nvim-copilot-extension.ui").submit_input()
    end, { buffer = panel.buf, silent = true, desc = "CopilotExt submit prompt" })

    vim.keymap.set("i", "<C-j>", "<CR>", { buffer = panel.buf, desc = "CopilotExt newline in prompt" })

    vim.keymap.set("n", "i", function()
      require("nvim-copilot-extension.ui").focus_prompt()
    end, { buffer = panel.buf, silent = true, desc = "CopilotExt focus prompt" })

    vim.keymap.set("n", "e", function()
      require("nvim-copilot-extension.ui").edit_message_at_cursor()
    end, { buffer = panel.buf, silent = true, desc = "CopilotExt edit previous user message" })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMoved", "CursorMovedI" }, {
      buffer = panel.buf,
      callback = protect_input,
      desc = "CopilotExt protect transcript",
    })

    render({ input_lines = { "" } })
  end

  local cfg = config.get()
  local width = cfg.panel.width
  if width < 1 then
    width = math.max(36, math.floor(vim.o.columns * width))
  end

  if cfg.panel.side == "left" then
    vim.cmd("topleft vertical " .. width .. "split")
  else
    vim.cmd("botright vertical " .. width .. "split")
  end
  panel.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel.win, panel.buf)
  vim.wo[panel.win].wrap = true
end

local function finalize_response(answer, err, errors)
  if errors then
    for _, item in ipairs(errors) do
      append_message("system_note", { content = item })
    end
  end

  if err then
    if panel.active_assistant_id then
      finish_active_assistant("")
    end
    append_message("error", { content = err })
    focus_input(false)
    return
  end

  finish_active_assistant(answer or "")
  diff.preview_from_response(answer)
  focus_input(false)
end

local function run_chat(messages, errors)
  start_assistant_message()
  client.chat_stream(messages, {
    on_delta = function(_, full)
      update_active_assistant(full)
    end,
    on_error = function(err)
      finalize_response(nil, err, errors)
    end,
    on_done = function(answer)
      finalize_response(answer, nil, errors)
    end,
  })
end

local function send_message(prompt, rerun_message_id)
  local expanded, meta = slash.expand(prompt)
  if meta and meta.action == "clear" then
    M.clear()
    return
  elseif meta and meta.action == "handled" then
    render()
    return
  elseif not expanded then
    return
  end

  if rerun_message_id then
    local message = get_message(rerun_message_id)
    if not message then
      append_message("error", { content = "Edited message not found" })
      return
    end
    message.content = expanded
    trim_after_message(rerun_message_id)
  else
    append_message("user", { content = expanded })
  end

  panel.composer.editing_id = nil
  local enriched, errors = context.to_message(expanded)
  local system = "You are a VS Code-like Copilot assistant running in Neovim. Be concise, practical, and preserve user control."
  local instructions = context.instructions(config.get().instructions)
  if instructions and instructions ~= "" then
    system = system .. "\n\nUser/repository instructions:\n" .. instructions
  end
  if state.mode() == "edit" then
    system = system .. " When changing code, prefer unified diff blocks."
  end

  if state.mode() == "agent" then
    local assistant_message = start_assistant_message({ pending = true })
    agent.run(expanded, {
      on_assistant_start = function()
        update_message_content(assistant_message.id, "", { pending = true })
      end,
      on_assistant_delta = function(_, full)
        update_message_content(assistant_message.id, full, { pending = false })
      end,
      on_tool = function(call)
        append_message("tool_call", {
          content = tools.format_call(call),
          meta = { call = call, parent_id = assistant_message.id },
        })
      end,
      on_tool_result = function(call, output, err)
        append_message("tool_result", {
          content = tools.format_result(call, output, err),
          meta = { call = call, output = output, err = err, parent_id = assistant_message.id },
        })
      end,
      on_finish = function(answer, err, agent_errors)
        if agent_errors then
          for _, item in ipairs(agent_errors) do
            append_message("system_note", { content = item })
          end
        end
        if err then
          finish_active_assistant("")
          append_message("error", { content = err })
          focus_input(false)
          return
        end
        finish_active_assistant(answer or "")
      end,
    })
    return
  end

  local messages = {
    { role = "system", content = system },
  }

  for _, item in ipairs(conversation_messages()) do
    table.insert(messages, item)
  end
  messages[#messages].content = enriched
  run_chat(messages, errors)
end

function M.open()
  ensure_panel()
  render()
  focus_input(false)
end

function M.close()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_close(panel.win, true)
  end
  panel.win = nil
end

function M.toggle()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    M.close()
  else
    M.open()
  end
end

function M.clear()
  ensure_panel()
  panel.messages = {}
  panel.active_assistant_id = nil
  panel.composer.editing_id = nil
  render({ input_lines = { "" } })
  focus_input(false)
end

function M.send(prompt)
  ensure_panel()
  local rerun_id = panel.composer.editing_id
  send_message(prompt, rerun_id)
end

function M.quick_prompt()
  vim.ui.input({ prompt = "Copilot: " }, function(input)
    if input then
      M.send(input)
    end
  end)
end

function M.submit_input()
  ensure_panel()
  local prompt = current_input_text()
  if prompt == "" then
    focus_input(true)
    return
  end
  set_input_lines({ "" })
  vim.cmd("stopinsert")
  M.send(prompt)
end

function M.focus_prompt()
  focus_input(true)
end

function M.edit_message_at_cursor()
  if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(panel.win)
  local message = message_for_line(cursor[1])
  if not message or message.kind ~= "user" then
    vim.notify("Move the cursor onto a previous user message to edit it", vim.log.levels.INFO)
    return
  end

  panel.composer.editing_id = message.id
  render({ input_lines = vim.split(message.content or "", "\n", { plain = true }) })
  focus_input(true)
end

function M.inline_edit(opts)
  local has_range = opts and opts.range and opts.range > 0
  local active_visual = vim.fn.mode() == "v" or vim.fn.mode() == "V" or vim.fn.mode() == "\22"
  local prompt = "Edit the selected code. Return a unified diff. #selection #buffer"
  if not has_range and not active_visual then
    prompt = "Edit the current line in context. Return a unified diff. #buffer"
  end
  M.send(prompt)
end

vim.api.nvim_create_autocmd("User", {
  pattern = "CopilotExtStateChanged",
  callback = function()
    if panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then
      render()
    end
  end,
})

return M
