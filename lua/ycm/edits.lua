-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Apply ycmd's one-based byte-range edits to Neovim buffers.

local request = require("ycm.request")

local M = {}

local function buffer_for_file(filepath)
	local wanted = vim.uv.fs_realpath(filepath) or filepath
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local path = vim.api.nvim_buf_get_name(bufnr)
		if path ~= "" and (vim.uv.fs_realpath(path) or path) == wanted then
			vim.fn.bufload(bufnr)
			return bufnr
		end
	end
	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)
	return bufnr
end

local function split_replacement(text)
	return vim.split(text or "", "\n", { plain = true, trimempty = false })
end

local function apply_chunk(bufnr, chunk)
	local range = chunk.range
	local start = range.start
	local finish = range["end"]
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local start_line = math.max(0, math.min(start.line_num - 1, line_count - 1))
	local end_line = math.max(start_line, math.min(finish.line_num - 1, line_count - 1))
	local start_text = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1, true)[1] or ""
	local end_text = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, true)[1] or ""
	local start_column = math.max(0, math.min(start.column_num - 1, #start_text))
	local end_column = math.max(0, math.min(finish.column_num - 1, #end_text))
	vim.api.nvim_buf_set_text(
		bufnr,
		start_line,
		start_column,
		end_line,
		end_column,
		split_replacement(chunk.replacement_text)
	)
	return {
		bufnr = bufnr,
		filename = request.filepath(bufnr),
		lnum = start_line + 1,
		col = start_column + 1,
		text = chunk.replacement_text or "",
		type = "F",
	}
end

function M.apply(chunks, options)
	options = options or {}
	local by_file = {}
	local unopened = {}
	for index, chunk in ipairs(chunks or {}) do
		local filepath = chunk.range.start.filepath
		by_file[filepath] = by_file[filepath] or {}
		chunk._ycm_order = index
		by_file[filepath][#by_file[filepath] + 1] = chunk
		if vim.fn.bufnr(filepath) < 0 then
			unopened[filepath] = true
		end
	end

	if not options.silent and vim.tbl_count(unopened) > 0 then
		local answer = vim.fn.confirm(
			("YCM must load %d additional file(s) to apply this change. Continue?"):format(vim.tbl_count(unopened)),
			"&Yes\n&No",
			1
		)
		if answer ~= 1 then
			return false
		end
	end

	local locations = {}
	for filepath, file_chunks in pairs(by_file) do
		table.sort(file_chunks, function(left, right)
			local lstart = left.range.start
			local rstart = right.range.start
			if lstart.line_num ~= rstart.line_num then
				return lstart.line_num > rstart.line_num
			end
			if lstart.column_num ~= rstart.column_num then
				return lstart.column_num > rstart.column_num
			end
			return left._ycm_order > right._ycm_order
		end)
		local bufnr = buffer_for_file(filepath)
		for _, chunk in ipairs(file_chunks) do
			chunk._ycm_order = nil
			locations[#locations + 1] = apply_chunk(bufnr, chunk)
		end
	end

	if not options.silent then
		if #locations > 0 then
			vim.fn.setqflist({}, "r", { title = "YCM applied changes", items = locations })
		end
		vim.notify(("Applied %d changes"):format(#(chunks or {})))
	end
	return true
end

return M
