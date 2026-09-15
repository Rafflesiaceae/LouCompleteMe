-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Serialize Neovim buffers and byte positions into ycmd request data.

local M = {}

local unnamed_paths = {}

local function absolute_path(path)
	local result = vim.fn.fnamemodify(path, ":p")
	return result == "/" and result or result:gsub("/$", "")
end

local function filetypes(bufnr)
	local filetype = vim.bo[bufnr].filetype
	if filetype == "" then
		return { "ycm_nofiletype" }
	end
	return vim.split(filetype, ".", { plain = true })
end

function M.filepath(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name ~= "" then
		return absolute_path(name)
	end
	if not unnamed_paths[bufnr] then
		unnamed_paths[bufnr] = absolute_path(vim.uv.cwd() .. "/" .. tostring(bufnr))
	end
	return unnamed_paths[bufnr]
end

local function buffer_data(bufnr)
	return {
		contents = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n") .. "\n",
		filetypes = filetypes(bufnr),
	}
end

local function file_data(included)
	local data = { [M.filepath(included)] = buffer_data(included) }
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if bufnr ~= included and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
			data[M.filepath(bufnr)] = buffer_data(bufnr)
		end
	end
	return data
end

function M.build(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local current = bufnr == vim.api.nvim_get_current_buf()
	local cursor = current and vim.api.nvim_win_get_cursor(0) or { 1, 0 }
	return {
		filepath = M.filepath(bufnr),
		line_num = cursor[1],
		column_num = cursor[2] + 1,
		working_dir = vim.uv.cwd(),
		file_data = file_data(bufnr),
	}
end

function M.filetypes(bufnr)
	return filetypes(bufnr or vim.api.nvim_get_current_buf())
end

function M.add_extra_conf_data(data)
	local expressions = vim.g.ycm_extra_conf_vim_data or {}
	if #expressions == 0 then
		return data
	end
	data.extra_conf_data = {}
	for _, expression in ipairs(expressions) do
		local ok, value = pcall(vim.fn.eval, expression)
		if ok then
			data.extra_conf_data[expression] = value
		else
			vim.notify("Error evaluating '" .. expression .. "': " .. value, vim.log.levels.WARN)
		end
	end
	return data
end

function M.add_tags(data)
	if vim.g.ycm_collect_identifiers_from_tags_files ~= 1 then
		return data
	end
	data.tag_files = {}
	for _, path in ipairs(vim.fn.tagfiles()) do
		data.tag_files[#data.tag_files + 1] = absolute_path(path)
	end
	return data
end

function M.add_ultisnips_data(data)
	if vim.g.ycm_use_ultisnips_completer ~= 1 then
		return data
	end

	local ok = pcall(vim.fn["UltiSnips#SnippetsInCurrentScope"], 1)
	if not ok then
		return data
	end

	local snippets = vim.g.current_ulti_dict_info
	if type(snippets) ~= "table" then
		return data
	end
	data.ultisnips_snippets = {}
	for trigger, snippet in pairs(snippets) do
		data.ultisnips_snippets[#data.ultisnips_snippets + 1] = {
			trigger = trigger,
			description = type(snippet) == "table" and snippet.description or "",
		}
	end
	table.sort(data.ultisnips_snippets, function(left, right)
		return left.trigger < right.trigger
	end)
	return data
end

function M.range(first_line, last_line)
	local bufnr = vim.api.nvim_get_current_buf()
	local last_text = vim.api.nvim_buf_get_lines(bufnr, last_line - 1, last_line, true)[1] or ""
	return {
		range = {
			start = {
				filepath = M.filepath(bufnr),
				line_num = first_line,
				column_num = 1,
			},
			["end"] = {
				filepath = M.filepath(bufnr),
				line_num = last_line,
				column_num = #last_text + 1,
			},
		},
	}
end

return M
