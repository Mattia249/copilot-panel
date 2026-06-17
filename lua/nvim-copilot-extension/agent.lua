local client = require("nvim-copilot-extension.client")
local config = require("nvim-copilot-extension.config")
local context = require("nvim-copilot-extension.context")
local state = require("nvim-copilot-extension.state")
local tools = require("nvim-copilot-extension.tools")

local M = {}

local known_tools = {
  read = true,
  search = true,
  edit = true,
  execute = true,
  todo = true,
  web = true,
  browser = true,
}

local function extract_json_candidate(text)
  if not text or text == "" then
    return nil
  end

  local fenced = text:match("```json%s*(.-)%s*```")
  if fenced and fenced ~= "" then
    return fenced
  end

  local start_pos = text:find("{", 1, true)
  if not start_pos then
    return nil
  end

  local depth = 0
  local in_string = false
  local escaped = false
  for index = start_pos, #text do
    local char = text:sub(index, index)
    if in_string then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        in_string = false
      end
    else
      if char == '"' then
        in_string = true
      elseif char == "{" then
        depth = depth + 1
      elseif char == "}" then
        depth = depth - 1
        if depth == 0 then
          return text:sub(start_pos, index)
        end
      end
    end
  end

  return text
end

local function decode_json_block(text)
  if not text or text == "" then
    return nil
  end

  local candidate = extract_json_candidate(text)
  if not candidate or candidate == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, candidate)
  if ok and type(decoded) == "table" then
    return decoded
  end
end

local function normalize_response(decoded)
  if type(decoded) ~= "table" then
    return nil
  end

  if type(decoded.type) == "string" and known_tools[decoded.type] and decoded.tool == nil then
    local tool_name = decoded.type
    local args = vim.deepcopy(decoded)
    args.type = nil
    args.reason = nil
    return {
      type = "tool_call",
      tool = tool_name,
      args = args,
      reason = decoded.reason,
    }
  end

  if decoded.type == "final" and type(decoded.content) == "string" then
    local nested = decode_json_block(decoded.content)
    local normalized_nested = normalize_response(nested)
    if normalized_nested and normalized_nested.type == "tool_call" then
      return normalized_nested
    end
  end

  return decoded
end

local function system_prompt()
  local cfg = config.get()
  local agent_name = state.agent()
  local agent_profile = cfg.agent.profiles[agent_name] or cfg.agent.profiles[cfg.agent.default] or ""
  local instructions = context.instructions(cfg.instructions)

  local chunks = {
    "You are running inside Neovim as a local coding agent with tool access.",
    "Active agent profile: " .. agent_name .. ". " .. agent_profile,
    "Use tools when needed instead of guessing workspace state.",
    "Respond with exactly one JSON object and no markdown.",
    'To use a tool, respond with: {"type":"tool_call","tool":"read","args":{...},"reason":"optional"}',
    'When you are done, respond with: {"type":"final","content":"your final answer"}',
    "Do not include explanatory prose before or after a tool JSON object.",
    "Keep tool calls focused and minimal.",
    "When editing files, prefer the smallest safe change.",
    "Prefer edit action=replace for targeted text changes and action=append for adding content at the end of a file.",
    "Do not rewrite an entire file with action=set unless the user explicitly asked to replace the whole file.",
    "When you produce final content, write it as the user-facing answer.",
    "After tools succeed, give a short summary and do not repeat raw tool logs, JSON, or absolute paths.",
    cfg.agent.require_approval and "Edits and shell commands may require approval; if denied, adapt and continue." or "",
    tools.describe(),
  }

  if instructions and instructions ~= "" then
    table.insert(chunks, "User/repository instructions:\n" .. instructions)
  end

  return table.concat(chunks, "\n\n")
end

local function append_tool_result(messages, call, output, err)
  table.insert(messages, {
    role = "user",
    content = vim.json.encode({
      type = "tool_result",
      tool = call.tool,
      ok = err == nil,
      output = output,
      error = err,
    }),
  })
end

local function stream_text(text, handlers)
  if handlers.on_assistant_start then
    handlers.on_assistant_start()
  end

  local chunks = {}
  for piece in tostring(text or ""):gmatch("%S+%s*") do
    table.insert(chunks, piece)
  end
  if #chunks == 0 then
    chunks = { "" }
  end

  local index = 0
  local built = ""
  local function push()
    index = index + 1
    if index > #chunks then
      if handlers.on_finish then
        handlers.on_finish(built, nil)
      end
      return
    end

    built = built .. chunks[index]
    if handlers.on_assistant_delta then
      handlers.on_assistant_delta(chunks[index], built)
    end
    vim.defer_fn(push, 15)
  end

  push()
end

function M.run(history_messages, errors, handlers)
  handlers = handlers or {}
  local cfg = config.get()
  local messages = {
    { role = "system", content = system_prompt() },
  }
  for _, message in ipairs(history_messages or {}) do
    table.insert(messages, message)
  end
  local step = 0
  local max_steps = cfg.agent.max_steps or 8
  local assistant_started = false

  local function start_assistant_once()
    if assistant_started then
      return
    end
    assistant_started = true
    if handlers.on_assistant_start then
      handlers.on_assistant_start()
    end
  end

  local function finish(answer, err)
    if err then
      if handlers.on_finish then
        handlers.on_finish(nil, err, errors)
      end
      return
    end
    stream_text(answer or "", {
      on_assistant_start = start_assistant_once,
      on_assistant_delta = handlers.on_assistant_delta,
      on_finish = function(final_answer)
        if handlers.on_finish then
          handlers.on_finish(final_answer, nil, errors)
        end
      end,
    })
  end

  local function run_step()
    step = step + 1
    if step > max_steps then
      finish(nil, "Agent reached the maximum number of steps")
      return
    end

    client.chat(messages, function(answer, err)
      if err then
        finish(nil, err)
        return
      end

      local decoded = normalize_response(decode_json_block(answer))
      if not decoded then
        finish(answer, nil)
        return
      end

      if decoded.type == "final" then
        finish(decoded.content or "", nil)
        return
      end

      if decoded.type ~= "tool_call" or type(decoded.tool) ~= "string" then
        finish(answer, nil)
        return
      end

      start_assistant_once()
      table.insert(messages, {
        role = "assistant",
        content = vim.json.encode(decoded),
      })

      if handlers.on_tool then
        handlers.on_tool(decoded)
      end

      tools.execute(decoded, function(output, tool_err)
        if handlers.on_tool_result then
          handlers.on_tool_result(decoded, output, tool_err)
        end
        append_tool_result(messages, decoded, output, tool_err)
        run_step()
      end)
    end)
  end

  run_step()
end

return M
