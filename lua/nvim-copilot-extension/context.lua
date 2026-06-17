local M = {}
local workspace_cache = {
	cwd = nil,
	files = nil,
}

local function path_matches_prefix(path, prefix)
	if prefix == "" then
		return true
	end

	local lowered_path = path:lower()
	local lowered_prefix = prefix:lower()
	return lowered_path:find(lowered_prefix, 1, true) == 1 or lowered_path:find("/" .. lowered_prefix, 1, true) ~= nil
end

local function normalize_path(path)
	local normalized = path:gsub("\\", "/")
	return normalized
end

local function workspace_files(force_refresh)
	local cwd = vim.fn.getcwd()
	if not force_refresh and workspace_cache.cwd == cwd and workspace_cache.files then
		return workspace_cache.files
	end

	local files = {}
	if vim.fn.executable("rg") == 1 then
		local result = vim.system({ "rg", "--files" }, { cwd = cwd, text = true }):wait()
		if result.code == 0 and result.stdout and result.stdout ~= "" then
			for _, line in ipairs(vim.split(result.stdout, "\n", { plain = true })) do
				local trimmed = vim.trim(line)
				if trimmed ~= "" then
					table.insert(files, normalize_path(trimmed))
				end
			end
		end
	end

	if #files == 0 then
		local found = vim.fn.globpath(cwd, "**/*", false, true)
		for _, item in ipairs(found) do
			if vim.fn.isdirectory(item) ~= 1 then
				local relative = vim.fn.fnamemodify(item, ":.")
				table.insert(files, normalize_path(relative))
			end
		end
	end

	table.sort(files)
	workspace_cache.cwd = cwd
	workspace_cache.files = files
	return files
end

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

local function each_at_file_ref(prompt, cb)
	local search_from = 1
	while true do
		local start_pos, end_pos, _, candidate = prompt:find("()@([^%s]+)", search_from)
		if not start_pos then
			break
		end
		local previous = start_pos > 1 and prompt:sub(start_pos - 1, start_pos - 1) or ""
		if start_pos == 1 or previous:match("[%s%(%[%{,]") then
			cb(candidate)
		end
		search_from = end_pos + 1
	end
end

local function resolve_file_ref(path)
	local direct = vim.fn.fnamemodify(path, ":p")
	if vim.fn.filereadable(direct) == 1 then
		return path
	end

	local matches = M.complete_file_refs(path)
	if #matches == 1 then
		return matches[1]
	end

	if #matches > 1 then
		local preview = {}
		for index = 1, math.min(#matches, 5) do
			table.insert(preview, matches[index])
		end
		local suffix = #matches > #preview and ", ..." or ""
		return nil, string.format(
			'Ambiguous #file reference "%s". Matches: %s%s',
			path,
			table.concat(preview, ", "),
			suffix
		)
	end

	return nil, "File not readable: " .. path
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
		local resolved, resolve_err = resolve_file_ref(file)
		local ctx, err = resolved and file_context(resolved) or nil, resolve_err
		if ctx then
			if resolved ~= file then
				ctx.title = string.format("#file:%s -> %s", file, resolved)
			end
			table.insert(refs, ctx)
		else
			table.insert(errors, err)
		end
	end

	each_at_file_ref(prompt, function(file)
		local resolved, resolve_err = resolve_file_ref(file)
		local ctx, err = resolved and file_context(resolved) or nil, resolve_err
		if ctx then
			if resolved ~= file then
				ctx.title = string.format("@%s -> %s", file, resolved)
			else
				ctx.title = "@" .. resolved
			end
			table.insert(refs, ctx)
		else
			table.insert(errors, err)
		end
	end)

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

function M.complete_file_refs(prefix)
	local matches = {}
	local lowered = (prefix or ""):lower()
	for attempt = 1, 2 do
		matches = {}
		for _, path in ipairs(workspace_files(attempt == 2)) do
			if path_matches_prefix(path, lowered) then
				table.insert(matches, path)
			end
		end
		if #matches > 0 or attempt == 2 then
			break
		end
	end
	return matches
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
