# nvim-copilot-extension

A Neovim Copilot chat and agent companion designed for LazyVim users.

The plugin reuses the authentication already created by the default Copilot
setup (`zbirenbaum/copilot.lua` or `github/copilot.vim`) and adds a VS Code-like
experience: a side chat panel, runtime model and mode switching, inline edits,
file references, slash commands, and a conservative local agent loop.

CopilotExt reuses `copilot.lua` credentials from `~/.config/github-copilot/auth.db`
when possible. If that database is unavailable, it falls back to
`GITHUB_COPILOT_TOKEN` or `GH_COPILOT_TOKEN`.

## Install

```lua
{
  "matti/nvim-copilot-extension",
  dependencies = {
    "zbirenbaum/copilot.lua",
  },
  opts = {
    panel = { side = "right", width = 0.36 },
    model = { default = "default", persist = true },
    mode = { default = "chat", persist = true },
    agent = { require_approval = true },
  },
}
```

## Commands

- `:CopilotExtToggle` opens or closes the chat panel.
- `:CopilotExtChat [prompt]` sends a chat prompt.
- `:CopilotExtQuickPrompt` opens a small prompt input.
- `:CopilotExtNewChat` starts a fresh chat session.
- `:CopilotExtChats` browses and reopens previous chat sessions.
- `:CopilotExtDeleteChat` deletes the current chat session.
- `:CopilotExtAcceptAllChanges` accepts every pending AI edit in the current file.
- `:CopilotExtInlineEdit` edits the visual selection or current line.
- `:CopilotExtApplyLastDiff` applies the currently reviewed diff, skipping rejected hunks.
- `:CopilotExtReviewLastDiff` reopens the last diff review window.
- `:CopilotExtAuth` starts the `copilot.lua` sign-in flow.
- `:CopilotExtAuthInfo` shows `copilot.lua` authentication details/token info.
- `:CopilotExtMode chat|edit|agent` changes mode at runtime.
- `:CopilotExtSelectMode` opens the runtime mode picker.
- `:CopilotExtAgent implementer|reviewer|tester|planner` changes agent profile at runtime.
- `:CopilotExtSelectAgent` opens the runtime agent picker.
- `:CopilotExtModel <model>` changes model at runtime.
- `:CopilotExtSelectModel` opens the runtime model picker.
- `:CopilotExtModels` lists Copilot chat models available from the Copilot API.
- `:CopilotExtTools` lists the agent tools available in Neovim.
- `:CopilotExtStatus` prints current auth, model, and mode.
- `:checkhealth nvim-copilot-extension` checks `curl`, Copilot auth, and runtime state.

In the side panel, type in the `Prompt` area at the bottom. Press `<Enter>` to
send and `<C-j>` to insert a newline. Responses stream into the panel as tokens
arrive. Move the cursor onto a previous `You` message and press `e` to edit and
resend the conversation from that point. While typing `#file:` in the prompt,
the panel suggests workspace files automatically; use `<Tab>` and `<S-Tab>` to
navigate the suggestions, `<Enter>` to confirm the current suggestion, and
`<C-Space>` to trigger completion manually.

Chats are persisted across sessions, can be reopened from `:CopilotExtChats`,
and keep conversational context between messages in both chat and agent mode.

Default chat keymaps:

- `<leader>ac` browses saved chats
- `<leader>an` starts a new chat
- `<leader>ad` deletes the current chat

When Copilot returns a unified diff, the extension opens a dedicated diff review
split. Each hunk can be reviewed independently:

- `a` marks the current hunk as accepted
- `r` marks the current hunk as rejected
- `u` resets the current hunk back to pending
- `]c` and `[c` jump between hunks
- `A` applies all pending/accepted hunks and skips rejected ones
- `q` closes the review window

When the AI proposes direct file edits through tools, the extension no longer
opens a blocking approval popup. Instead it opens the target file with inline
pending changes:

- changed blocks are highlighted in place
- added lines appear inline as virtual diff rows
- `y` accepts the block under the cursor
- `n` rejects the block under the cursor
- `A` accepts every pending block in the file

## Authentication

Use `:CopilotExtAuth` to start the same sign-in flow as `:Copilot auth signin`.
This creates the encrypted `~/.config/github-copilot/auth.db` used by
`copilot.lua`.

If auth.db cannot be read on your machine, set a Copilot token in one of:

```bash
export GITHUB_COPILOT_TOKEN=...
# or
export GH_COPILOT_TOKEN=...
```

## Prompt context

Use VS Code-style references in prompts:

- `#file:path/to/file`
- `#buffer`
- `#selection`
- `#diagnostics`
- `#workspace`

`#file:` also accepts an unambiguous partial workspace path such as
`#file:README` or `#file:lua/nvim-copilot-extension/ui`.

Slash commands are supported for common actions:

- `/explain`
- `/fix`
- `/tests`
- `/doc`
- `/refactor`
- `/commit`
- `/clear`
- `/model`
- `/mode`
- `/agent`

Default agent profiles are `implementer`, `reviewer`, `tester`, and `planner`.

## Agent tools

In `agent` mode the extension can call local tools for:

- `read`: read workspace files with optional line ranges
- `search`: search the workspace with `rg`
- `edit`: create, append, overwrite, or replace file contents
- `execute`: run shell commands
- `todo`: manage a local todo list for planning
- `web`: fetch a URL or run a simple web search
- `browser`: open a URL in your system browser

`edit` and `execute` require approval by default.

Ciao mamma sono in tv!
