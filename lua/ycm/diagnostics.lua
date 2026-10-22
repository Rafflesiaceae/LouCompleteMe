-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Render ycmd diagnostics through Neovim's native diagnostic API.

local request = require("ycm.request")

local Diagnostics = {}
Diagnostics.__index = Diagnostics

local function severity(diagnostic)
	if diagnostic.kind == "ERROR" then
		return vim.diagnostic.severity.ERROR
	end
	return vim.diagnostic.severity.WARN
end

local function clamp_position(bufnr, position)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local line = math.max(1, math.min(position.line_num or 1, line_count))
	local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, true)[1] or ""
	local column = math.max(1, math.min(position.column_num or 1, #text + 1))
	return line - 1, column - 1
end

local function diagnostic_range(bufnr, diagnostic)
	local extent = diagnostic.location_extent or {}
	local start = extent.start or {}
	local finish = extent["end"] or {}
	if (start.line_num or 0) <= 0 then
		local line, column = clamp_position(bufnr, diagnostic.location or {})
		return line, column, line, column + 1
	end
	local line, column = clamp_position(bufnr, start)
	local end_line, end_column = clamp_position(bufnr, finish)
	return line, column, end_line, math.max(end_column, column + 1)
end

local function compiled_filters(filetypes)
	local configuration = vim.g.ycm_filter_diagnostics or {}
	local filters = {}
	for _, filetype in ipairs(filetypes) do
		local spec = configuration[filetype] or {}
		local levels = spec.level
		if levels ~= nil and type(levels) ~= "table" then
			levels = { levels }
		end
		for _, level in ipairs(levels or {}) do
			filters[#filters + 1] = function(diagnostic)
				return diagnostic.kind == tostring(level):upper()
			end
		end
		local expressions = spec.regex
		if expressions ~= nil and type(expressions) ~= "table" then
			expressions = { expressions }
		end
		for _, expression in ipairs(expressions or {}) do
			local ok, regex = pcall(vim.regex, "\\c" .. expression)
			if ok then
				filters[#filters + 1] = function(diagnostic)
					return regex:match_str(diagnostic.text or "") ~= nil
				end
			end
		end
	end
	return filters
end

local function allowed(diagnostic, filters)
	for _, filter in ipairs(filters) do
		if filter(diagnostic) then
			return false
		end
	end
	return true
end

function Diagnostics.new()
	local namespace = vim.api.nvim_create_namespace("ycm_diagnostics")
	vim.diagnostic.config({
		underline = vim.g.ycm_enable_diagnostic_highlighting == 1,
		signs = vim.g.ycm_enable_diagnostic_signs == 1 and {
			text = {
				[vim.diagnostic.severity.ERROR] = vim.g.ycm_error_symbol or ">>",
				[vim.diagnostic.severity.WARN] = vim.g.ycm_warning_symbol or ">>",
			},
		} or false,
		virtual_text = vim.g.ycm_echo_current_diagnostic == "virtual-text",
		severity_sort = true,
		update_in_insert = vim.g.ycm_update_diagnostics_in_insert_mode == 1,
	}, namespace)
	return setmetatable({
		namespace = namespace,
		raw = {},
	}, Diagnostics)
end

function Diagnostics:update(bufnr, diagnostics, open_location_list)
	if vim.g.ycm_show_diagnostics_ui ~= 1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local filters = compiled_filters(request.filetypes(bufnr))
	local converted = {}
	local kept = {}
	for _, diagnostic in ipairs(diagnostics or {}) do
		if allowed(diagnostic, filters) then
			local line, column, end_line, end_column = diagnostic_range(bufnr, diagnostic)
			converted[#converted + 1] = {
				lnum = line,
				col = column,
				end_lnum = end_line,
				end_col = end_column,
				severity = severity(diagnostic),
				message = diagnostic.text or "",
				source = "YCM",
				user_data = diagnostic,
			}
			kept[#kept + 1] = diagnostic
		end
	end
	local maximum = tonumber(vim.g.ycm_max_diagnostics_to_display) or 0
	if maximum > 0 then
		while #converted > maximum do
			table.remove(converted)
			table.remove(kept)
		end
	end
	self.raw[bufnr] = kept
	vim.diagnostic.set(self.namespace, bufnr, converted)
	if
		bufnr == vim.api.nvim_get_current_buf()
		and (vim.g.ycm_always_populate_location_list == 1 or open_location_list)
	then
		vim.diagnostic.setloclist({ namespace = self.namespace, open = open_location_list })
	end
end

function Diagnostics:update_for_file(filepath, diagnostics)
	local wanted = vim.uv.fs_realpath(filepath) or filepath
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local path = request.filepath(bufnr)
			if (vim.uv.fs_realpath(path) or path) == wanted then
				self:update(bufnr, diagnostics, false)
				return
			end
		end
	end
end

function Diagnostics:counts(bufnr)
	local errors = #vim.diagnostic.get(bufnr, {
		namespace = self.namespace,
		severity = vim.diagnostic.severity.ERROR,
	})
	local warnings = #vim.diagnostic.get(bufnr, {
		namespace = self.namespace,
		severity = vim.diagnostic.severity.WARN,
	})
	return errors, warnings
end

-- Fit a diagnostic message on a single command-line row so echoing it never
-- triggers a hit-enter prompt. Multiline messages (e.g. clang's "In included
-- file: ..." notes) are flattened and anything that does not fit is cut off
-- with an ellipsis. The full text stays available via :YcmShowDetailedDiagnostic.
function Diagnostics.echo_text(message)
	local text = tostring(message):gsub("%s+", " ")
	-- Leave room for the last column plus 'showcmd' and 'ruler' which share
	-- the command-line row.
	local width = vim.o.columns - 1
	if vim.o.showcmd then
		width = width - 11
	end
	if vim.o.ruler then
		width = width - 18
	end
	width = math.max(width, 10)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	local count = vim.fn.strchars(text)
	while count > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, count)) > width - 3 do
		count = count - 1
	end
	return vim.fn.strcharpart(text, 0, count) .. "..."
end

-- Echo the diagnostic on the cursor line without ever blocking the editor.
function Diagnostics:echo_current()
	local values = vim.diagnostic.get(0, {
		namespace = self.namespace,
		lnum = vim.api.nvim_win_get_cursor(0)[1] - 1,
	})
	if values[1] then
		-- history=false: do not pollute :messages on every cursor movement
		pcall(vim.api.nvim_echo, { { Diagnostics.echo_text(values[1].message) } }, false, {})
	end
end

function Diagnostics:show_current()
	vim.diagnostic.open_float(0, {
		namespace = self.namespace,
		scope = "cursor",
		focus = false,
	})
end

function Diagnostics:clear(bufnr)
	self.raw[bufnr] = nil
	vim.diagnostic.reset(self.namespace, bufnr)
end

return Diagnostics
