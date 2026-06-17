local M = {}

local last_review = nil
local ns = vim.api.nvim_create_namespace("copilot-extension-diff")

local function split_lines(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function flatten_hunks(review)
  review.hunks = {}
  for _, file in ipairs(review.files or {}) do
    for _, hunk in ipairs(file.hunks or {}) do
      table.insert(review.hunks, hunk)
    end
  end
end

local function create_file_review(header_lines)
  return {
    header_lines = vim.deepcopy(header_lines or {}),
    hunks = {},
    path = nil,
  }
end

local function current_review()
  return last_review
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CopilotExtDiffTitle", { link = "Title" })
  vim.api.nvim_set_hl(0, "CopilotExtDiffHint", { link = "Comment" })
  vim.api.nvim_set_hl(0, "CopilotExtDiffAccepted", { link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "CopilotExtDiffRejected", { link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CopilotExtDiffPending", { link = "Special" })
  vim.api.nvim_set_hl(0, "CopilotExtDiffApplied", { link = "String" })
end

local function status_text(status)
  if status == "accepted" then
    return "[accepted]"
  end
  if status == "rejected" then
    return "[rejected]"
  end
  if status == "applied" then
    return "[applied]"
  end
  return "[pending]"
end

local function status_hl(status)
  if status == "accepted" then
    return "CopilotExtDiffAccepted"
  end
  if status == "rejected" then
    return "CopilotExtDiffRejected"
  end
  if status == "applied" then
    return "CopilotExtDiffApplied"
  end
  return "CopilotExtDiffPending"
end

local function parse_file_path(header_lines)
  for _, line in ipairs(header_lines or {}) do
    local path = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
    if path and path ~= "/dev/null" then
      return path
    end
  end

  for _, line in ipairs(header_lines or {}) do
    local from_diff = line:match("^diff %-%-git a/(.+) b/(.+)$")
    if from_diff then
      return select(2, line:match("^diff %-%-git a/(.+) b/(.+)$"))
    end
  end
end

local function parse_diff(text)
  local lines = split_lines(text)
  local review = {
    raw = text,
    files = {},
    hunks = {},
    line_to_hunk = {},
    buf = nil,
    win = nil,
  }

  local current_file = nil
  local current_hunk = nil
  local file_header = {}

  local function ensure_file()
    if current_file then
      return current_file
    end
    current_file = create_file_review(file_header)
    table.insert(review.files, current_file)
    file_header = {}
    return current_file
  end

  local function flush_hunk()
    if not current_hunk then
      return
    end
    ensure_file()
    table.insert(current_file.hunks, current_hunk)
    current_hunk = nil
  end

  local function flush_file()
    flush_hunk()
    if current_file then
      current_file.path = parse_file_path(current_file.header_lines)
      current_file = nil
    end
  end

  for _, line in ipairs(lines) do
    if line:match("^diff %-%-git ") then
      flush_file()
      file_header = { line }
    elseif line:match("^@@ ") then
      ensure_file()
      flush_hunk()
      current_hunk = {
        file = current_file,
        header = line,
        lines = { line },
        status = "pending",
      }
    elseif current_hunk then
      table.insert(current_hunk.lines, line)
    else
      table.insert(file_header, line)
    end
  end

  flush_file()

  if #review.files == 0 and #lines > 0 then
    local fallback = create_file_review({})
    fallback.path = "[diff]"
    fallback.hunks = {
      {
        file = fallback,
        header = "@@",
        lines = lines,
        status = "pending",
      },
    }
    table.insert(review.files, fallback)
  end

  flatten_hunks(review)
  return review
end

local function build_review_lines(review)
  local lines = {
    "Copilot Diff Review",
    "",
    "a accept  r reject  u reset  ]c next hunk  [c previous hunk  A apply reviewed diff  q close",
    "",
  }
  review.line_to_hunk = {}

  for _, file in ipairs(review.files or {}) do
    table.insert(lines, "File: " .. (file.path or "[unknown]"))
    table.insert(lines, "")
    for _, line in ipairs(file.header_lines or {}) do
      table.insert(lines, line)
    end
    if #(file.header_lines or {}) > 0 then
      table.insert(lines, "")
    end

    for _, hunk in ipairs(file.hunks or {}) do
      hunk.header_line = #lines + 1
      for _, line in ipairs(hunk.lines or {}) do
        table.insert(lines, line)
      end
      hunk.end_line = #lines
      for row = hunk.header_line, hunk.end_line do
        review.line_to_hunk[row] = hunk
      end
      table.insert(lines, "")
    end
  end

  return lines
end

local function current_hunk()
  local review = current_review()
  if not review or not review.win or not vim.api.nvim_win_is_valid(review.win) then
    return nil, review
  end

  local cursor = vim.api.nvim_win_get_cursor(review.win)
  return review.line_to_hunk[cursor[1]], review
end

local function decorate_review(review)
  if not review or not review.buf or not vim.api.nvim_buf_is_valid(review.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(review.buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(review.buf, ns, "CopilotExtDiffTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(review.buf, ns, "CopilotExtDiffHint", 2, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local zero = row - 1
    if line:match("^File: ") then
      vim.api.nvim_buf_add_highlight(review.buf, ns, "CopilotExtDiffHint", zero, 0, -1)
    end
  end

  for _, hunk in ipairs(review.hunks or {}) do
    if hunk.header_line then
      vim.api.nvim_buf_set_extmark(review.buf, ns, hunk.header_line - 1, 0, {
        virt_text = {
          { " " .. status_text(hunk.status) .. "  ", status_hl(hunk.status) },
          { "a accept  r reject", "CopilotExtDiffHint" },
        },
        virt_text_pos = "eol",
      })
    end
  end
end

local function render_review(review)
  if not review or not review.buf or not vim.api.nvim_buf_is_valid(review.buf) then
    return
  end

  local cursor = nil
  if review.win and vim.api.nvim_win_is_valid(review.win) then
    cursor = vim.api.nvim_win_get_cursor(review.win)
  end

  local lines = build_review_lines(review)
  vim.bo[review.buf].modifiable = true
  vim.api.nvim_buf_set_lines(review.buf, 0, -1, false, lines)
  vim.bo[review.buf].modifiable = false
  vim.bo[review.buf].modified = false
  decorate_review(review)

  if cursor and review.win and vim.api.nvim_win_is_valid(review.win) then
    local row = math.max(1, math.min(cursor[1], vim.api.nvim_buf_line_count(review.buf)))
    local line = vim.api.nvim_buf_get_lines(review.buf, row - 1, row, false)[1] or ""
    local col = math.max(0, math.min(cursor[2], #line))
    pcall(vim.api.nvim_win_set_cursor, review.win, { row, col })
  end
end

local function set_hunk_status(status)
  local hunk, review = current_hunk()
  if not hunk or not review then
    vim.notify("Move the cursor onto a diff hunk first", vim.log.levels.INFO)
    return
  end
  if hunk.status == "applied" then
    vim.notify("This hunk has already been applied", vim.log.levels.INFO)
    return
  end
  hunk.status = status
  render_review(review)
end

local function move_hunk(step)
  local review = current_review()
  if not review or not review.win or not vim.api.nvim_win_is_valid(review.win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(review.win)
  local target = nil
  if step > 0 then
    for _, hunk in ipairs(review.hunks or {}) do
      if hunk.header_line and hunk.header_line > cursor[1] then
        target = hunk
        break
      end
    end
  else
    for index = #(review.hunks or {}), 1, -1 do
      local hunk = review.hunks[index]
      if hunk.header_line and hunk.header_line < cursor[1] then
        target = hunk
        break
      end
    end
  end

  if target and target.header_line then
    pcall(vim.api.nvim_win_set_cursor, review.win, { target.header_line, 0 })
  end
end

local function included_hunks(file)
  local hunks = {}
  for _, hunk in ipairs(file.hunks or {}) do
    if hunk.status ~= "rejected" and hunk.status ~= "applied" then
      table.insert(hunks, hunk)
    end
  end
  return hunks
end

local function build_patch(review)
  local chunks = {}
  for _, file in ipairs(review.files or {}) do
    local hunks = included_hunks(file)
    if #hunks > 0 then
      for _, line in ipairs(file.header_lines or {}) do
        table.insert(chunks, line)
      end
      for _, hunk in ipairs(hunks) do
        for _, line in ipairs(hunk.lines or {}) do
          table.insert(chunks, line)
        end
      end
    end
  end
  return table.concat(chunks, "\n")
end

local function run_git_apply(diff_text, args, cb)
  local diff_file = vim.fn.tempname()
  vim.fn.writefile(split_lines(diff_text), diff_file)

  local command = vim.list_extend({ "git", "apply" }, args or {})
  table.insert(command, diff_file)

  vim.system(command, { text = true, cwd = vim.fn.getcwd() }, function(result)
    vim.schedule(function()
      vim.fn.delete(diff_file)
      cb(result)
    end)
  end)
end

local function mark_applied(review)
  for _, file in ipairs(review.files or {}) do
    for _, hunk in ipairs(file.hunks or {}) do
      if hunk.status ~= "rejected" then
        hunk.status = "applied"
      end
    end
  end
end

local function apply_reviewed()
  local review = current_review()
  if not review then
    vim.notify("No CopilotExt diff review available", vim.log.levels.WARN)
    return
  end

  local diff_text = build_patch(review)
  if diff_text == "" then
    vim.notify("No accepted or pending hunks left to apply", vim.log.levels.WARN)
    return
  end

  run_git_apply(diff_text, { "--check" }, function(check)
    if check.code ~= 0 then
      vim.notify("CopilotExt diff check failed: " .. vim.trim(check.stderr or ""), vim.log.levels.ERROR)
      return
    end

    run_git_apply(diff_text, {}, function(result)
      if result.code ~= 0 then
        vim.notify("CopilotExt diff apply failed: " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
        return
      end

      mark_applied(review)
      render_review(review)
      vim.notify("CopilotExt reviewed diff applied", vim.log.levels.INFO)
      vim.cmd("checktime")
    end)
  end)
end

local function ensure_review_buffer(review)
  setup_highlights()

  if review.buf and vim.api.nvim_buf_is_valid(review.buf) then
    return
  end

  review.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[review.buf].filetype = "diff"
  vim.bo[review.buf].buftype = "nofile"
  vim.bo[review.buf].bufhidden = "hide"
  vim.api.nvim_buf_set_name(review.buf, "Copilot Diff Review")

  vim.keymap.set("n", "q", function()
    if review.win and vim.api.nvim_win_is_valid(review.win) then
      vim.api.nvim_win_close(review.win, true)
      review.win = nil
    end
  end, { buffer = review.buf, silent = true, desc = "Close CopilotExt diff review" })

  vim.keymap.set("n", "a", function()
    set_hunk_status("accepted")
  end, { buffer = review.buf, silent = true, desc = "Accept CopilotExt diff hunk" })

  vim.keymap.set("n", "r", function()
    set_hunk_status("rejected")
  end, { buffer = review.buf, silent = true, desc = "Reject CopilotExt diff hunk" })

  vim.keymap.set("n", "u", function()
    set_hunk_status("pending")
  end, { buffer = review.buf, silent = true, desc = "Reset CopilotExt diff hunk" })

  vim.keymap.set("n", "]c", function()
    move_hunk(1)
  end, { buffer = review.buf, silent = true, desc = "Next CopilotExt diff hunk" })

  vim.keymap.set("n", "[c", function()
    move_hunk(-1)
  end, { buffer = review.buf, silent = true, desc = "Previous CopilotExt diff hunk" })

  vim.keymap.set("n", "A", function()
    apply_reviewed()
  end, { buffer = review.buf, silent = true, desc = "Apply reviewed CopilotExt diff" })
end

function M.show(text)
  local review = parse_diff(text)
  ensure_review_buffer(review)

  vim.cmd("botright split")
  review.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(review.win, review.buf)
  vim.api.nvim_win_set_height(review.win, math.max(12, math.floor(vim.o.lines * 0.35)))
  vim.wo[review.win].wrap = false
  render_review(review)

  if review.hunks[1] and review.hunks[1].header_line then
    pcall(vim.api.nvim_win_set_cursor, review.win, { review.hunks[1].header_line, 0 })
  end

  last_review = review
  return review.buf
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
    M.show(diff)
    return true
  end
  return false
end

function M.last()
  return last_review and last_review.raw or nil
end

function M.open_last_review()
  if not last_review or not last_review.raw or last_review.raw == "" then
    vim.notify("No CopilotExt diff review available", vim.log.levels.WARN)
    return
  end
  M.show(last_review.raw)
end

function M.apply_last()
  if not last_review or not last_review.raw or last_review.raw == "" then
    vim.notify("No CopilotExt diff to apply", vim.log.levels.WARN)
    return
  end
  apply_reviewed()
end

function M._parse_for_test(text)
  return parse_diff(text)
end

function M._build_patch_for_test(review)
  return build_patch(review)
end

return M
