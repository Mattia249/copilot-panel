local auth = require("nvim-copilot-extension.auth")
local config = require("nvim-copilot-extension.config")
local models = require("nvim-copilot-extension.models")
local state = require("nvim-copilot-extension.state")

local M = {}

local function request_body(model, messages, stream)
  return {
    messages = messages,
    stream = stream,
    model = model,
  }
end

local function curl_args(token, body)
  return {
    "curl",
    "-sS",
    "-N",
    "-X",
    "POST",
    "-H",
    "Authorization: Bearer " .. token,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-H",
    "Editor-Version: Neovim/0.11.0",
    "-H",
    "Editor-Plugin-Version: copilot-panel/0.1.0",
    "-H",
    "Copilot-Integration-Id: vscode-chat",
    "-d",
    vim.json.encode(body),
    config.get().endpoint,
  }
end

function M.chat(messages, cb)
  local job = { inner = nil, cancelled = false }

  models.resolve(state.model(), function(model, model_err)
    if not model then
      cb(nil, model_err)
      return
    end

    auth.get_token(function(token, err)
      if not token then
        cb(nil, err)
        return
      end

      if job.cancelled then
        return
      end

      local body = request_body(model, messages, false)

      job.inner = vim.system(curl_args(token, body), { text = true }, function(result)
        job.inner = nil
        vim.schedule(function()
          if result.code ~= 0 then
            cb(nil, result.stderr)
            return
          end

          local ok, decoded = pcall(vim.json.decode, result.stdout)
          if not ok then
            cb(nil, "Invalid Copilot response")
            return
          end

          if decoded.error then
            cb(nil, decoded.error.message or vim.json.encode(decoded.error))
            return
          end

          local content = decoded
            and decoded.choices
            and decoded.choices[1]
            and decoded.choices[1].message
            and decoded.choices[1].message.content

          cb(content or result.stdout)
        end)
      end)
    end)
  end)

  function job:kill(signal)
    self.cancelled = true
    if self.inner and self.inner.kill then
      self.inner:kill(signal or "sigterm")
    end
  end

  return job
end

local function parse_sse_line(line)
  local data = line:match("^data:%s*(.*)$")
  if not data or data == "" or data == "[DONE]" then
    return nil, data == "[DONE]"
  end

  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or decoded.error then
    return nil, false, decoded and decoded.error and decoded.error.message or nil
  end

  local choice = decoded.choices and decoded.choices[1]
  local delta = choice and choice.delta
  local content = delta and delta.content
  if type(content) ~= "string" then
    return nil, false
  end
  return content, false
end

function M.chat_stream(messages, handlers)
  handlers = handlers or {}
  models.resolve(state.model(), function(model, model_err)
    if not model then
      if handlers.on_error then
        handlers.on_error(model_err)
      end
      return
    end

    auth.get_token(function(token, err)
      if not token then
        if handlers.on_error then
          handlers.on_error(err)
        end
        return
      end

      local full = ""
      local done_sent = false
      local pending = ""

      local function consume_line(line)
        local delta, done, line_err = parse_sse_line(line)
        if line_err and handlers.on_error then
          vim.schedule(function()
            handlers.on_error(line_err)
          end)
          return
        end

        if delta and delta ~= "" then
          full = full .. delta
          if handlers.on_delta then
            vim.schedule(function()
              handlers.on_delta(delta, full)
            end)
          end
        end

        if done and handlers.on_done and not done_sent then
          done_sent = true
          vim.schedule(function()
            handlers.on_done(full)
          end)
        end
      end

      local job_id = vim.fn.jobstart(curl_args(token, request_body(model, messages, true)), {
        stdout_buffered = false,
        stderr_buffered = false,
        on_stdout = function(_, data)
          if not data or #data == 0 then
            return
          end

          data[1] = pending .. data[1]
          pending = table.remove(data) or ""

          for _, line in ipairs(data) do
            consume_line(line:gsub("\r$", ""))
          end
        end,
        on_stderr = function(_, _)
          -- curl stderr is intentionally ignored while streaming; non-zero exit is reported on completion.
        end,
        on_exit = function(_, code)
          if pending ~= "" then
            consume_line(pending:gsub("\r$", ""))
            pending = ""
          end

          vim.schedule(function()
            if code ~= 0 and handlers.on_error then
              handlers.on_error("Streaming request failed")
            elseif handlers.on_done and not done_sent then
              done_sent = true
              handlers.on_done(full)
            end
          end)
        end,
      })

      if handlers.on_start then
        handlers.on_start(job_id)
      end
    end)
  end)
end

return M
