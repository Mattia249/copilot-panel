local M = {}

local last_diff = nil

function M.show(text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "diff"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))

  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.max(8, math.floor(vim.o.lines * 0.3)))
  return buf
end

function M.extract_diff(text)
  if not text then
    return nil
  end

  local fenced = text:match("```diff\n(.-)\n```")
  if fenced then
    return fenced
  end
  if text:find("^diff %-%-git", 1) or text:find("\n@@ ", 1, true) then
    return text
  end
end

function M.preview_from_response(text)
  local diff = M.extract_diff(text)
  if diff then
    last_diff = diff
    M.show(diff)
    return true
  end
  return false
end

function M.last()
  return last_diff
end

local function run_git_apply(args, cb)
  local diff_file = vim.fn.tempname()
  vim.fn.writefile(vim.split(last_diff, "\n", { plain = true }), diff_file)

  local command = vim.list_extend({ "git", "apply" }, args)
  table.insert(command, diff_file)

  vim.system(command, { text = true, cwd = vim.fn.getcwd() }, function(result)
    vim.schedule(function()
      vim.fn.delete(diff_file)
      cb(result)
    end)
  end)
end

function M.apply_last()
  if not last_diff or last_diff == "" then
    vim.notify("No CopilotExt diff to apply", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Apply", "Cancel" }, {
    prompt = "Apply last CopilotExt diff?",
  }, function(choice)
    if choice ~= "Apply" then
      return
    end

    run_git_apply({ "--check" }, function(check)
      if check.code ~= 0 then
        vim.notify("CopilotExt diff check failed: " .. (check.stderr or ""), vim.log.levels.ERROR)
        return
      end

      run_git_apply({}, function(result)
        if result.code == 0 then
          vim.notify("CopilotExt diff applied", vim.log.levels.INFO)
          vim.cmd("checktime")
        else
          vim.notify("CopilotExt diff apply failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

return M
