local M = {}

local function current_buffer()
  local name = vim.api.nvim_buf_get_name(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return {
    title = "#buffer " .. (name ~= "" and name or "[No Name]"),
    body = table.concat(lines, "\n"),
  }
end

local function visual_selection()
  local mode = vim.fn.mode()
  local start_pos
  local end_pos

  if mode == "v" or mode == "V" or mode == "\22" then
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getpos(".")
  else
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
    if start_pos[2] == 0 or end_pos[2] == 0 then
      return nil
    end
  end

  local start_line = math.min(start_pos[2], end_pos[2])
  local end_line = math.max(start_pos[2], end_pos[2])
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  return {
    title = "#selection",
    body = table.concat(lines, "\n"),
  }
end

local function diagnostics()
  local items = vim.diagnostic.get(0)
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, string.format("L%d: %s", item.lnum + 1, item.message))
  end
  return {
    title = "#diagnostics",
    body = table.concat(lines, "\n"),
  }
end

local function file_context(path)
  local resolved = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(resolved) ~= 1 then
    return nil, "File not readable: " .. path
  end
  return {
    title = "#file:" .. path,
    body = table.concat(vim.fn.readfile(resolved), "\n"),
  }
end

function M.parse_references(prompt)
  local refs = {}
  local errors = {}

  if prompt:find("#buffer", 1, true) then
    table.insert(refs, current_buffer())
  end

  if prompt:find("#selection", 1, true) then
    local selection = visual_selection()
    if selection then
      table.insert(refs, selection)
    else
      table.insert(errors, "No active visual selection")
    end
  end

  if prompt:find("#diagnostics", 1, true) then
    table.insert(refs, diagnostics())
  end

  for file in prompt:gmatch("#file:([^%s]+)") do
    local ctx, err = file_context(file)
    if ctx then
      table.insert(refs, ctx)
    else
      table.insert(errors, err)
    end
  end

  if prompt:find("#workspace", 1, true) then
    table.insert(refs, {
      title = "#workspace",
      body = "Workspace root: " .. vim.fn.getcwd(),
    })
  end

  return refs, errors
end

function M.to_message(prompt)
  local refs, errors = M.parse_references(prompt)
  local chunks = { prompt }

  for _, ref in ipairs(refs) do
    table.insert(chunks, "\n\n[" .. ref.title .. "]\n```text\n" .. ref.body .. "\n```")
  end

  return table.concat(chunks, ""), errors
end

function M.instructions(setting)
  if setting == false or setting == nil then
    return nil
  end

  local candidates = {}
  if setting == "auto" or setting == true then
    candidates = {
      ".github/copilot-instructions.md",
      ".copilot-instructions.md",
    }
  elseif type(setting) == "string" then
    candidates = { setting }
  elseif type(setting) == "table" then
    candidates = setting
  end

  for _, path in ipairs(candidates) do
    local resolved = vim.fn.fnamemodify(path, ":p")
    if vim.fn.filereadable(resolved) == 1 then
      return table.concat(vim.fn.readfile(resolved), "\n")
    end
  end
end

return M
