local M = {}

local ns = vim.api.nvim_create_namespace("copilot-panel-edit-review")
local reviews_by_buf = {}

local function split_lines(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function join_lines(lines)
  return table.concat(lines or {}, "\n")
end

local function slice_lines(lines, start_line, count)
  local result = {}
  if count <= 0 then
    return result
  end
  for index = start_line, start_line + count - 1 do
    table.insert(result, lines[index] or "")
  end
  return result
end

local function trim_common_edges(hunk)
  local current_slice = vim.deepcopy(hunk.current_slice or {})
  local desired_slice = vim.deepcopy(hunk.desired_slice or {})
  local current_start = hunk.current_start
  local desired_start = hunk.desired_start

  while #current_slice > 0 and #desired_slice > 0 and current_slice[1] == desired_slice[1] do
    table.remove(current_slice, 1)
    table.remove(desired_slice, 1)
    current_start = current_start + 1
    desired_start = desired_start + 1
  end

  while #current_slice > 0 and #desired_slice > 0 and current_slice[#current_slice] == desired_slice[#desired_slice] do
    table.remove(current_slice)
    table.remove(desired_slice)
  end

  hunk.current_start = current_start
  hunk.desired_start = desired_start
  hunk.current_slice = current_slice
  hunk.desired_slice = desired_slice
  hunk.current_count = #current_slice
  hunk.desired_count = #desired_slice

  local anchor_line = current_start
  if hunk.current_count == 0 then
    anchor_line = math.max(1, current_start - 1)
    if anchor_line > math.max(#hunk.buffer_lines, 1) then
      anchor_line = math.max(#hunk.buffer_lines, 1)
    end
  end
  hunk.anchor_line = anchor_line
end

local function short_path(path)
  local value = vim.trim(path or "")
  if value == "" then
    return "[unknown]"
  end
  return value:gsub("\\", "/"):match("([^/]+)$") or value
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CopilotExtPendingDelete", { link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CopilotExtPendingAdd", { link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "CopilotExtPendingHint", { link = "Comment" })
  vim.api.nvim_set_hl(0, "CopilotExtPendingBubble", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "CopilotExtPendingBubbleKey", { fg = "#a6e3a1", bg = "#313244", bold = true })
end

local function current_file_lines(resolved)
  if vim.fn.filereadable(resolved) ~= 1 then
    return {}
  end
  return vim.fn.readfile(resolved)
end

local function diff_hunks(current_lines, desired_lines)
  local ok, hunks = pcall(vim.diff, join_lines(current_lines), join_lines(desired_lines), {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
  })
  if not ok or type(hunks) ~= "table" then
    return {}
  end
  return hunks
end

local function visible_target_win(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

local function open_target_buffer(resolved)
  local buf = vim.fn.bufnr(resolved, true)
  if vim.fn.bufloaded(buf) ~= 1 then
    vim.fn.bufload(buf)
  end

  local win = visible_target_win(buf)
  if win then
    return buf, win
  end

  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current_win)
  local current_name = vim.api.nvim_buf_get_name(current_buf)
  if current_name:match("Copilot Panel$") then
    pcall(vim.cmd, "wincmd p")
  end

  vim.cmd("edit " .. vim.fn.fnameescape(resolved))
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

local function write_review_file(review)
  vim.fn.mkdir(vim.fn.fnamemodify(review.resolved, ":h"), "p")
  vim.fn.writefile(review.current_lines, review.resolved)

  if review.buf and vim.api.nvim_buf_is_valid(review.buf) then
    local was_modifiable = vim.bo[review.buf].modifiable
    vim.bo[review.buf].modifiable = true
    vim.api.nvim_buf_set_lines(review.buf, 0, -1, false, review.current_lines)
    vim.bo[review.buf].modifiable = was_modifiable
    vim.bo[review.buf].modified = false
  end

  vim.cmd("checktime " .. vim.fn.fnameescape(review.resolved))
end

local function clear_review(review)
  if not review or not review.buf or not vim.api.nvim_buf_is_valid(review.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(review.buf, ns, 0, -1)
  reviews_by_buf[review.buf] = nil
end

local function rebuild_hunks(review)
  review.hunks = {}
  review.line_to_hunk = {}

  local hunks = diff_hunks(review.current_lines, review.desired_lines)
  for index, item in ipairs(hunks) do
    local current_start, current_count, desired_start, desired_count = unpack(item)
    local hunk = {
      id = index,
      current_start = current_start,
      current_count = current_count,
      desired_start = desired_start,
      desired_count = desired_count,
      anchor_line = current_start,
      buffer_lines = review.current_lines,
      current_slice = slice_lines(review.current_lines, current_start, current_count),
      desired_slice = slice_lines(review.desired_lines, desired_start, desired_count),
    }
    trim_common_edges(hunk)

    if not (hunk.current_count == 0 and hunk.desired_count == 0) then
      table.insert(review.hunks, hunk)
      if hunk.current_count > 0 then
        for row = hunk.current_start, hunk.current_start + hunk.current_count - 1 do
          review.line_to_hunk[row] = hunk
        end
      end
      review.line_to_hunk[hunk.anchor_line] = hunk
    end
  end
end

local function render(review)
  if not review or not review.buf or not vim.api.nvim_buf_is_valid(review.buf) then
    return
  end

  setup_highlights()
  rebuild_hunks(review)
  vim.api.nvim_buf_clear_namespace(review.buf, ns, 0, -1)

  if #review.hunks == 0 then
    clear_review(review)
    vim.notify("CopilotPanel: all suggested changes resolved for " .. short_path(review.path), vim.log.levels.INFO)
    return
  end

  for _, hunk in ipairs(review.hunks) do
    if hunk.current_count > 0 then
      for row = hunk.current_start, hunk.current_start + hunk.current_count - 1 do
        vim.api.nvim_buf_set_extmark(review.buf, ns, row - 1, 0, {
          line_hl_group = "CopilotExtPendingDelete",
          hl_eol = true,
        })
      end
    end

    local virt_lines = {}
    for _, line in ipairs(hunk.desired_slice or {}) do
      table.insert(virt_lines, { { "+ " .. line, "CopilotExtPendingAdd" } })
    end

    local extmark_row = math.max(hunk.anchor_line - 1, 0)
    vim.api.nvim_buf_set_extmark(review.buf, ns, extmark_row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
      virt_text = {
        { " Accept changes? ", "CopilotExtPendingBubble" },
        { "y", "CopilotExtPendingBubbleKey" },
        { "/", "CopilotExtPendingBubble" },
        { "n", "CopilotExtPendingBubbleKey" },
        { "/", "CopilotExtPendingBubble" },
        { "A", "CopilotExtPendingBubbleKey" },
        { " all ", "CopilotExtPendingBubble" },
      },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end

  reviews_by_buf[review.buf] = review
end

local function current_review()
  local buf = vim.api.nvim_get_current_buf()
  return reviews_by_buf[buf]
end

local function current_hunk(review)
  if not review then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return review.line_to_hunk[row]
end

local function replace_range(lines, start_line, count, replacement)
  local result = {}
  for i = 1, math.max(start_line - 1, 0) do
    table.insert(result, lines[i])
  end
  for _, line in ipairs(replacement or {}) do
    table.insert(result, line)
  end
  for i = start_line + count, #lines do
    table.insert(result, lines[i])
  end
  return result
end

local function attach_buffer_keymaps(buf)
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "y", function()
    require("nvim-copilot-extension.edit_review").accept_current()
  end, vim.tbl_extend("force", opts, { desc = "CopilotPanel accept pending edit hunk" }))
  vim.keymap.set("n", "n", function()
    require("nvim-copilot-extension.edit_review").reject_current()
  end, vim.tbl_extend("force", opts, { desc = "CopilotPanel reject pending edit hunk" }))
  vim.keymap.set("n", "A", function()
    require("nvim-copilot-extension.edit_review").accept_all()
  end, vim.tbl_extend("force", opts, { desc = "CopilotPanel accept all pending edits" }))
end

function M.propose(path, desired_text)
  local resolved = vim.fn.fnamemodify(path, ":p")
  local buf, win = open_target_buffer(resolved)
  if vim.bo[buf].modified then
    return nil, "Save or discard local changes in " .. short_path(path) .. " before accepting AI edits"
  end

  local review = reviews_by_buf[buf]
  if review then
    clear_review(review)
  end

  review = {
    path = path,
    resolved = resolved,
    buf = buf,
    win = win,
    current_lines = current_file_lines(resolved),
    desired_lines = split_lines(desired_text),
    hunks = {},
    line_to_hunk = {},
  }

  attach_buffer_keymaps(buf)
  render(review)
  reviews_by_buf[buf] = review
  return #review.hunks, short_path(path)
end

function M.accept_current()
  local review = current_review()
  local hunk = current_hunk(review)
  if not review or not hunk then
    vim.notify("Move the cursor onto a pending Copilot change first", vim.log.levels.INFO)
    return
  end

  review.current_lines = replace_range(review.current_lines, hunk.current_start, hunk.current_count, hunk.desired_slice)
  write_review_file(review)
  render(review)
end

function M.reject_current()
  local review = current_review()
  local hunk = current_hunk(review)
  if not review or not hunk then
    vim.notify("Move the cursor onto a pending Copilot change first", vim.log.levels.INFO)
    return
  end

  review.desired_lines = replace_range(review.desired_lines, hunk.desired_start, hunk.desired_count, hunk.current_slice)
  render(review)
end

function M.accept_all()
  local review = current_review()
  if not review then
    vim.notify("No pending Copilot edits in this buffer", vim.log.levels.INFO)
    return
  end

  review.current_lines = vim.deepcopy(review.desired_lines)
  write_review_file(review)
  clear_review(review)
  vim.notify("CopilotPanel: accepted all pending changes in " .. short_path(review.path), vim.log.levels.INFO)
end

function M.accept_all_global()
  local pending = {}
  for buf, review in pairs(reviews_by_buf) do
    if review and vim.api.nvim_buf_is_valid(buf) then
      table.insert(pending, review)
    end
  end

  if #pending == 0 then
    vim.notify("No pending Copilot edits across files", vim.log.levels.INFO)
    return
  end

  table.sort(pending, function(a, b)
    return (a.path or "") < (b.path or "")
  end)

  for _, review in ipairs(pending) do
    review.current_lines = vim.deepcopy(review.desired_lines)
    write_review_file(review)
    clear_review(review)
  end

  vim.notify(string.format("CopilotPanel: accepted all pending changes in %d file%s", #pending, #pending == 1 and "" or "s"), vim.log.levels.INFO)
end

function M.has_pending(buf)
  return reviews_by_buf[buf or vim.api.nvim_get_current_buf()] ~= nil
end

return M
