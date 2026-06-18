# Agent Guide for copilot-panel.nvim

This file is written for AI coding agents that need to understand and work on the project. It describes the actual project structure, technology stack, conventions, and anything else needed to make safe, useful changes.

## Project overview

`copilot-panel.nvim` is a Neovim plugin that adds a Copilot chat panel and a conservative local agent loop. It is designed for LazyVim users and reuses the authentication already created by `zbirenbaum/copilot.lua` or `github/copilot.vim`. The plugin provides a VS Code-like side panel, runtime model/mode/agent switching, inline edits, file references, slash commands, diff review, and tool-based agent actions.

The plugin exposes two module names for backwards compatibility:

- `copilot-panel` is the public alias.
- `nvim-copilot-extension` is the internal implementation namespace.

All real code lives under `lua/nvim-copilot-extension/`. The `lua/copilot-panel/` directory only re-exports the internal modules.

## Technology stack and dependencies

- **Language:** Lua (Neovim plugin).
- **Minimum Neovim:** The plugin targets Neovim 0.11+ based on API usage and the `Editor-Version` header sent to Copilot.
- **Required runtime dependencies:**
  - `curl` — used for all HTTP calls to the Copilot API and web tool.
  - A Copilot authentication source, normally one of:
    - `zbirenbaum/copilot.lua` or `github/copilot.vim` providing the `:Copilot` command.
    - `~/.config/github-copilot/auth.db` (read via `sqlite3` or `python3`).
    - `GITHUB_COPILOT_TOKEN` or `GH_COPILOT_TOKEN` environment variables.
- **Optional runtime dependencies:**
  - `sqlite3` or `python3` — for reading `auth.db` when copilot.lua credentials are unavailable.
  - `rg` (ripgrep) — for the `search` tool and workspace file completion.
  - `git` — for applying reviewed diffs.
  - `xdg-open`, `open`, or `cmd start` — for the `browser` tool.
- **No build system:** There is no `package.json`, `pyproject.toml`, `Cargo.toml`, `Makefile`, or similar build configuration. The plugin is loaded directly by Neovim's Lua runtime.
- **No tests:** The repository currently contains no automated test suite. The small `diff._parse_for_test` and `diff._build_patch_for_test` helpers exist only as internal hooks and are not exercised by any tests in the repo.

## Project structure

```text
.
├── LICENSE
├── README.md
├── plugin/
│   ├── copilot-panel.lua      # Plugin load guard for the public name
│   └── nvim-copilot-extension.lua # Plugin load guard; also loads copilot-panel guard
└── lua/
    ├── copilot-panel/
    │   ├── init.lua           # Public alias: returns nvim-copilot-extension
    │   └── health.lua         # Public alias: returns nvim-copilot-extension.health
    └── nvim-copilot-extension/
        ├── init.lua           # Public setup() entry point
        ├── config.lua         # Default options and option merging
        ├── state.lua          # Runtime model/mode/agent state + persistence
        ├── commands.lua       # User commands and keymaps
        ├── ui.lua             # Side panel buffer, rendering, input, and chat flow
        ├── client.lua         # Copilot API HTTP client (streaming and non-streaming)
        ├── auth.lua           # Token acquisition and sign-in helpers
        ├── models.lua         # Copilot model listing and resolution
        ├── context.lua        # Prompt reference parsing (#file, #buffer, etc.)
        ├── slash.lua          # Slash command expansion (/explain, /fix, etc.)
        ├── agent.lua          # Local agent loop and JSON tool parsing
        ├── tools.lua          # Tool implementations (read, search, edit, execute, todo, web, browser)
        ├── diff.lua           # Unified diff review UI
        ├── edit_review.lua    # Inline pending-change review UI
        ├── todo.lua           # In-memory todo list used by the agent
        └── chats.lua          # Chat session persistence
```

## Module responsibilities

- **`init.lua`** — Exposes `setup(opts)`, `toggle()`, `chat(prompt)`, and selector helpers. Wires config, chats, state, and commands together.
- **`config.lua`** — Defines defaults for panel layout, chat persistence, auth provider, model/mode/agent settings, keymaps, and the Copilot endpoint. All options are merged with `vim.tbl_deep_extend`.
- **`state.lua`** — Holds the current model, mode, and agent profile. Loads and saves a JSON file at `stdpath('state')/copilot-panel/state.json` when persistence is enabled. Fires `User CopilotPanelStateChanged` on changes.
- **`commands.lua`** — Creates all `:CopilotPanel*` user commands and maps the configurable keymaps. Avoids mapping keys set to `false` or `""`.
- **`ui.lua`** — Owns the side panel buffer and window. Renders header, transcript, and prompt; handles input keymaps (`<CR>`, `<C-j>`, `<Tab>`, `<S-Tab>`, `<C-Space>`, `i`, `e`); manages streaming assistant responses; dispatches chat, edit, and agent modes.
- **`client.lua`** — Makes `POST` requests to `config.endpoint` (`https://api.githubcopilot.com/chat/completions`). Uses `vim.system` for the non-streaming path and `vim.fn.jobstart` for Server-Sent Events streaming.
- **`auth.lua`** — Acquires a Copilot chat token by trying, in order: in-memory cache, environment variables, copilot.lua token, `auth.db` (sqlite3/python3), or `hosts.json` OAuth token exchange. Also provides `:CopilotPanelAuth` and `:CopilotPanelAuthInfo` wrappers around `:Copilot auth`.
- **`models.lua`** — Lists available Copilot chat models from `https://api.githubcopilot.com/models`, caches them for five minutes, resolves `default`, and formats model labels.
- **`context.lua`** — Parses `#file:`, `@`, `#buffer`, `#selection`, `#diagnostics`, and `#workspace` references; loads repository instructions from `.github/copilot-instructions.md` or `.copilot-instructions.md` when `instructions` is `"auto"`.
- **`slash.lua`** — Expands slash commands (`/explain`, `/fix`, `/tests`, `/doc`, `/refactor`, `/commit`, `/clear`, `/model`, `/mode`, `/agent`).
- **`agent.lua`** — Runs a bounded tool loop (`max_steps`, default 20). Expects the model to reply with JSON tool calls or a final JSON object. Includes loop-guard logic that warns the model when it repeats the exact same tool call.
- **`tools.lua`** — Implements the tool spec used by the agent. `edit` and `execute` require user approval when `agent.require_approval` is true.
- **`diff.lua`** — Parses unified diffs, opens a review split, and applies accepted hunks with `git apply`.
- **`edit_review.lua`** — Shows AI file edits as inline virtual diff blocks. Provides per-block and file-wide accept/reject keymaps (`y`, `n`, `A`).
- **`todo.lua`** — Simple in-memory todo list for the agent planner profile.
- **`chats.lua`** — Persists chat sessions to `stdpath('state')/copilot-panel/chats.json`, capped at `chat.max_sessions`.

## Build and test commands

There is no build step. To validate the plugin, open it in Neovim and run:

```vim
:checkhealth copilot-panel
```

Health checks verify that `curl` is available, the `:Copilot` command exists, and a Copilot token can be obtained.

Because there is no test framework configured, testing is currently manual:

1. Start Neovim with the plugin on `runtimepath`.
2. Run `:CopilotPanelAuth` if not already signed in.
3. Run `:CopilotPanelToggle` and send a message.
4. Test agent mode with `:CopilotPanelMode agent` and a prompt that exercises tools.
5. Verify diff review with a prompt that asks for a code patch.

## Code style guidelines

- Use two-space indentation and keep lines reasonable in length.
- Use `local M = {}` at the top of modules and `return M` at the bottom.
- Prefer `vim.tbl_*` helpers for table operations and `vim.deepcopy` when mutating shared data.
- Use `pcall` around operations that may fail (LSP client access, file reads, JSON decode).
- Buffer/window validity must be checked with `vim.api.nvim_buf_is_valid` and `vim.api.nvim_win_is_valid` before use.
- User notifications use `vim.notify` with appropriate log levels (`vim.log.levels.INFO`, `WARN`, `ERROR`).
- Avoid blocking the UI: use `vim.system` or `vim.fn.jobstart` for external commands and `vim.schedule` to update UI from callbacks.
- All command and keymap descriptions should start with `CopilotPanel` for discoverability.
- Use `require` inside callbacks/keymaps when necessary to avoid circular dependencies (e.g., `require("nvim-copilot-extension.ui")` inside keymaps).

## Testing instructions

- The repository has no automated tests. Do not add a test runner unless explicitly requested.
- When adding a new feature, manually exercise it through the `:CopilotPanel*` commands and keymaps listed in `README.md`.
- Run `:checkhealth copilot-panel` after auth or dependency changes.
- Test with both `require("copilot-panel").setup({})` and `require("nvim-copilot-extension").setup({})` to ensure both entry points work.

## Security considerations

- The plugin reads sensitive Copilot credentials from `~/.config/github-copilot/auth.db` and environment variables. Never log or persist tokens.
- `tools.execute` runs shell commands after user approval (unless `agent.require_approval` is disabled). Keep approval logic intact and do not bypass it.
- `tools.edit` proposes file changes through `edit_review.propose`, which does not write files until the user accepts the changes. Preserve this user-control boundary.
- Web requests in `tools.web` use `curl -L` to follow redirects. Do not change this to silently enable unsafe fetches without good reason.
- The plugin exchanges OAuth tokens via `https://api.github.com/copilot_internal/v2/token`. Keep traffic over HTTPS and do not introduce plain-HTTP endpoints.
- All file paths are resolved with `vim.fn.fnamemodify(..., ":p")`. Avoid accessing paths outside the current working directory unless the user explicitly references them.

## Development workflow

- Edit files under `lua/nvim-copilot-extension/`.
- If a change affects the public entry point or backwards compatibility, update both `lua/copilot-panel/` re-export files and `lua/nvim-copilot-extension/`.
- Restart Neovim to reload the plugin; there is no hot-reload infrastructure.
- Update `README.md` when user-facing commands, options, or behavior change.
- Keep `AGENTS.md` current if conventions, dependencies, or architecture change.
