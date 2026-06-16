local config = require("nvim-copilot-extension.config")
local todo = require("nvim-copilot-extension.todo")

local M = {}

local function tool_error(message)
  return nil, message
end

local function read_file(path, start_line, end_line)
  local resolved = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(resolved) ~= 1 then
    return tool_error("File not readable: " .. path)
  end

  local lines = vim.fn.readfile(resolved)
  local from_line = math.max(1, tonumber(start_line) or 1)
  local to_line = math.min(#lines, tonumber(end_line) or #lines)
  if to_line < from_line then
    return tool_error("Invalid line range")
  end

  local chunk = {}
  for i = from_line, to_line do
    table.insert(chunk, string.format("%4d | %s", i, lines[i]))
  end

  return table.concat({
    "Path: " .. resolved,
    string.format("Lines: %d-%d", from_line, to_line),
    table.concat(chunk, "\n"),
  }, "\n")
end

local function search_workspace(args)
  local query = vim.trim(args.query or "")
  if query == "" then
    return tool_error("search requires query")
  end

  local command
  if vim.fn.executable("rg") == 1 then
    command = {
      "rg",
      "--line-number",
      "--column",
      "--smart-case",
      "--max-count",
      tostring(args.max_results or 50),
      query,
      args.path or vim.fn.getcwd(),
    }
  else
    command = {
      "grep",
      "-RIn",
      query,
      args.path or vim.fn.getcwd(),
    }
  end

  local result = vim.system(command, { text = true }):wait()
  if result.code ~= 0 and (result.stdout or "") == "" then
    return "No matches"
  end

  return vim.trim(result.stdout or "")
end

local function request_approval(kind, summary, cb)
  if not config.get().agent.require_approval then
    cb(true)
    return
  end

  vim.schedule(function()
    vim.ui.select({ "Approve", "Deny" }, {
      prompt = string.format("Allow %s? %s", kind, summary),
    }, function(choice)
      cb(choice == "Approve")
    end)
  end)
end

local function edit_file(args, cb)
  local path = vim.trim(args.path or "")
  local action = args.action or "replace"
  if path == "" then
    cb(nil, "edit requires path")
    return
  end

  local resolved = vim.fn.fnamemodify(path, ":p")
  local summary = string.format("%s %s", action, resolved)

  request_approval("edit", summary, function(approved)
    if not approved then
      cb(nil, "Edit denied by user")
      return
    end

    local lines = {}
    if vim.fn.filereadable(resolved) == 1 then
      lines = vim.fn.readfile(resolved)
    elseif action ~= "create" and action ~= "set" then
      cb(nil, "File not readable: " .. path)
      return
    end

    if action == "create" or action == "set" then
      local content = args.content or ""
      vim.fn.mkdir(vim.fn.fnamemodify(resolved, ":h"), "p")
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), resolved)
      cb("Wrote file: " .. resolved)
      return
    end

    local old_text = args.old_text
    local new_text = args.new_text or ""
    if not old_text or old_text == "" then
      cb(nil, "edit.replace requires old_text")
      return
    end

    local content = table.concat(lines, "\n")
    local replaced, count = content:gsub(vim.pesc(old_text), new_text, tonumber(args.count) or 1)
    if count == 0 then
      cb(nil, "Text to replace not found")
      return
    end

    vim.fn.writefile(vim.split(replaced, "\n", { plain = true }), resolved)
    cb(string.format("Updated %s (%d replacement%s)", resolved, count, count == 1 and "" or "s"))
  end)
end

local function execute_command(args, cb)
  local command = vim.trim(args.command or "")
  if command == "" then
    cb(nil, "execute requires command")
    return
  end

  request_approval("command", command, function(approved)
    if not approved then
      cb(nil, "Command denied by user")
      return
    end

    local shell = vim.o.shell ~= "" and vim.o.shell or "sh"
    local shellcmdflag = vim.o.shellcmdflag ~= "" and vim.o.shellcmdflag or "-c"
    vim.system({ shell, shellcmdflag, command }, {
      text = true,
      cwd = args.cwd or vim.fn.getcwd(),
    }, function(result)
      vim.schedule(function()
        local parts = {
          "Exit code: " .. tostring(result.code),
        }
        if result.stdout and result.stdout ~= "" then
          table.insert(parts, "stdout:\n" .. vim.trim(result.stdout))
        end
        if result.stderr and result.stderr ~= "" then
          table.insert(parts, "stderr:\n" .. vim.trim(result.stderr))
        end
        cb(table.concat(parts, "\n\n"))
      end)
    end)
  end)
end

local function urlencode(value)
  return (value:gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function web_request(args, cb)
  if args.url and args.url ~= "" then
    vim.system({
      "curl",
      "-sS",
      "-L",
      args.url,
    }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          cb(nil, result.stderr ~= "" and result.stderr or "web fetch failed")
          return
        end
        cb(vim.trim(result.stdout))
      end)
    end)
    return
  end

  local query = vim.trim(args.query or "")
  if query == "" then
    cb(nil, "web requires url or query")
    return
  end

  local url = "https://duckduckgo.com/html/?q=" .. urlencode(query)
  vim.system({
    "curl",
    "-sS",
    "-L",
    url,
  }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(nil, result.stderr ~= "" and result.stderr or "web search failed")
        return
      end
      cb(vim.trim(result.stdout))
    end)
  end)
end

local function open_browser(args, cb)
  local url = vim.trim(args.url or "")
  if url == "" then
    cb(nil, "browser requires url")
    return
  end

  if vim.ui.open then
    vim.ui.open(url)
    cb("Opened URL in system browser: " .. url)
    return
  end

  local opener
  if vim.fn.has("mac") == 1 then
    opener = { "open", url }
  elseif vim.fn.has("win32") == 1 then
    opener = { "cmd", "/c", "start", "", url }
  else
    opener = { "xdg-open", url }
  end

  vim.system(opener, {}, function(result)
    vim.schedule(function()
      if result.code == 0 then
        cb("Opened URL in system browser: " .. url)
      else
        cb(nil, "Failed to open browser URL")
      end
    end)
  end)
end

local tool_specs = {
  {
    name = "read",
    description = "Read a file from the workspace. Args: { path, start_line?, end_line? }",
  },
  {
    name = "search",
    description = "Search the workspace with ripgrep. Args: { query, path?, max_results? }",
  },
  {
    name = "edit",
    description = "Create or edit a file with approval. Args: { path, action=create|set|replace, content?, old_text?, new_text?, count? }",
  },
  {
    name = "execute",
    description = "Run a shell command with approval. Args: { command, cwd? }",
  },
  {
    name = "todo",
    description = "Manage a local todo list. Args: { action=list|add|update|remove|clear, id?, text?, done? }",
  },
  {
    name = "web",
    description = "Fetch a URL or search the web. Args: { url } or { query }",
  },
  {
    name = "browser",
    description = "Open a URL in the system browser. Args: { url }",
  },
}

function M.describe()
  local lines = { "Available tools:" }
  for _, spec in ipairs(tool_specs) do
    table.insert(lines, string.format("- %s: %s", spec.name, spec.description))
  end
  return table.concat(lines, "\n")
end

function M.format_call(call)
  local tool = call.tool or call.name or "tool"
  local args = call.args or {}

  if tool == "edit" then
    local action = args.action or "edit"
    return string.format("%sing %s", action, args.path or "[unknown file]")
  end

  if tool == "read" then
    if args.start_line or args.end_line then
      return string.format("reading %s (%s-%s)", args.path or "[unknown file]", args.start_line or 1, args.end_line or "?")
    end
    return string.format("reading %s", args.path or "[unknown file]")
  end

  if tool == "search" then
    return string.format('searching %s for "%s"', args.path or "workspace", args.query or "")
  end

  if tool == "execute" then
    return string.format("running %s", args.command or "[command]")
  end

  if tool == "todo" then
    return string.format("todo %s", args.action or "list")
  end

  if tool == "web" then
    return args.url and ("fetching " .. args.url) or ('searching web for "' .. (args.query or "") .. '"')
  end

  if tool == "browser" then
    return "opening " .. (args.url or "[url]")
  end

  return tool
end

function M.format_result(call, output, err)
  if err then
    return string.format("%s failed: %s", call.tool or "tool", err)
  end

  local tool = call.tool or call.name or "tool"
  if tool == "edit" or tool == "browser" or tool == "todo" then
    return output or (tool .. " completed")
  end

  if tool == "execute" then
    return output or "command completed"
  end

  return output or (tool .. " completed")
end

function M.execute(call, cb)
  local name = call.tool or call.name
  local args = call.args or {}

  if name == "read" then
    local output, err = read_file(args.path or "", args.start_line, args.end_line)
    cb(output, err)
    return
  end

  if name == "search" then
    local output, err = search_workspace(args)
    cb(output, err)
    return
  end

  if name == "edit" then
    edit_file(args, cb)
    return
  end

  if name == "execute" then
    execute_command(args, cb)
    return
  end

  if name == "todo" then
    local output, err = todo.run(args)
    cb(output, err)
    return
  end

  if name == "web" then
    web_request(args, cb)
    return
  end

  if name == "browser" then
    open_browser(args, cb)
    return
  end

  cb(nil, "Unknown tool: " .. tostring(name))
end

return M
