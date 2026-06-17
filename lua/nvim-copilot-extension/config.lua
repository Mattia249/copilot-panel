local M = {}

local defaults = {
  panel = {
    side = "right",
    width = 0.36,
  },
  chat = {
    persist = true,
    max_sessions = 50,
  },
  auth = {
    provider = "auto",
  },
  model = {
    default = "default",
    persist = true,
    choices = {
      "default",
      "gpt-5.3-codex",
      "gpt-5.3-codex-spark",
      "gpt-5.4",
      "claude-sonnet-4.5",
    },
  },
  mode = {
    default = "chat",
    persist = true,
    choices = { "chat", "edit", "agent" },
  },
  keymaps = {
    toggle_panel = "<leader>aa",
    select_model = "<leader>am",
    select_mode = "<leader>aM",
    select_agent = "<leader>aA",
    select_chat = "<leader>ac",
    new_chat = "<leader>an",
    delete_chat = "<leader>ad",
    accept_all_changes = "<leader>ay",
    accept_all_changes_global = "<leader>aY",
    inline_edit = "<leader>ae",
    quick_prompt = "<leader>ap",
  },
  agent = {
    require_approval = true,
    max_steps = 8,
    default = "implementer",
    profiles = {
      implementer = "Implement features and fixes with concise plans and reviewable patches.",
      reviewer = "Review code for bugs, regressions, missing tests, and maintainability risks.",
      tester = "Design and update focused tests, fixtures, and verification steps.",
      planner = "Break ambiguous engineering work into concrete implementation steps.",
    },
  },
  instructions = "auto",
  endpoint = "https://api.githubcopilot.com/chat/completions",
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return options
end

return M
