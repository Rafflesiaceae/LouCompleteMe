-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Install the Neovim commands, mappings, and event handlers for YCM.

local Client = require("ycm.client")

local M = {
	client = nil,
	configured = false,
	last_char_inserted = true,
	completion_stopped = false,
}

local function client()
	if not M.client then
		M.client = Client.new()
	end
	return M.client
end

local function setup_completeopt()
	local values = vim.split(vim.o.completeopt, ",", { plain = true })
	values = vim.tbl_filter(function(value)
		return value ~= "menu" and value ~= "longest" and value ~= ""
	end, values)
	if not vim.tbl_contains(values, "menuone") then
		values[#values + 1] = "menuone"
	end
	vim.o.completeopt = table.concat(values, ",")
end

local function setup_mappings()
	local function completion_key(replacement, original)
		return function()
			return vim.fn.pumvisible() == 1 and replacement or original
		end
	end

	for _, key in ipairs(vim.g.ycm_key_list_select_completion or {}) do
		vim.keymap.set("i", key, completion_key("<C-n>", key), {
			expr = true,
			silent = true,
		})
	end
	for _, key in ipairs(vim.g.ycm_key_list_previous_completion or {}) do
		vim.keymap.set("i", key, completion_key("<C-p>", key), {
			expr = true,
			silent = true,
		})
	end
	for _, key in ipairs(vim.g.ycm_key_list_stop_completion or {}) do
		vim.keymap.set("i", key, function()
			M.completion_stopped = true
			client().completion_generation = client().completion_generation + 1
			return key
		end, { expr = true, silent = true })
	end

	local invoke = vim.g.ycm_key_invoke_completion
	if invoke and invoke ~= "" then
		vim.keymap.set("i", invoke, function()
			client():complete(true)
			return ""
		end, { expr = true, silent = true })
	end
	local detailed = vim.g.ycm_key_detailed_diagnostics
	if detailed and detailed ~= "" then
		vim.keymap.set("n", detailed, function()
			client().diagnostics:show_current()
		end, { silent = true })
	end

	vim.keymap.set("i", "<Plug>(YCMComplete)", function()
		client():complete(false)
		return ""
	end, { expr = true, silent = true })
	vim.keymap.set("n", "<Plug>(YCMHover)", function()
		client():hover()
	end, { silent = true })
	vim.keymap.set("n", "<Plug>(YCMFindSymbolInWorkspace)", function()
		M.find_symbol("workspace")
	end, { silent = true })
	vim.keymap.set("n", "<Plug>(YCMFindSymbolInDocument)", function()
		M.find_symbol("document")
	end, { silent = true })
	vim.keymap.set("i", "<Plug>(YCMToggleSignatureHelp)", "<Nop>", {
		silent = true,
	})
	vim.keymap.set("n", "<Plug>(YCMToggleInlayHints)", "<Nop>", {
		silent = true,
	})
	vim.keymap.set("n", "<Plug>(YCMTypeHierarchy)", function()
		vim.notify("YCM hierarchy UI has not yet been ported to Neovim.")
	end, { silent = true })
	vim.keymap.set("n", "<Plug>(YCMCallHierarchy)", function()
		vim.notify("YCM hierarchy UI has not yet been ported to Neovim.")
	end, { silent = true })
end

local function setup_commands()
	vim.api.nvim_create_user_command("YcmRestartServer", function()
		client():restart()
	end, {})
	vim.api.nvim_create_user_command("YcmDebugInfo", function()
		client():debug_info()
	end, {})
	vim.api.nvim_create_user_command("YcmCompleter", function(options)
		client():command(options.fargs, {
			modifiers = options.mods,
			range = options.range > 0,
			line1 = options.line1,
			line2 = options.line2,
		})
	end, {
		nargs = "*",
		range = true,
		complete = function(lead)
			local commands = client().subcommands[vim.api.nvim_get_current_buf()] or {}
			return vim.tbl_filter(function(value)
				return value:sub(1, #lead) == lead
			end, commands)
		end,
	})
	vim.api.nvim_create_user_command("YcmDiags", function()
		client():force_diagnostics(true)
	end, {})
	vim.api.nvim_create_user_command("YcmForceCompileAndDiagnostics", function()
		client():force_diagnostics(false)
	end, {})
	vim.api.nvim_create_user_command("YcmShowDetailedDiagnostic", function()
		client().diagnostics:show_current()
	end, { nargs = "?" })
	vim.api.nvim_create_user_command("YcmToggleLogs", function(options)
		local logs = {
			client().server.stdout_log,
			client().server.stderr_log,
		}
		local function open(path)
			if path and path ~= "" then
				vim.cmd.edit(vim.fn.fnameescape(path))
			end
		end
		if options.args ~= "" then
			for _, path in ipairs(logs) do
				if path and vim.fs.basename(path) == options.args then
					open(path)
					return
				end
			end
			return
		end
		vim.ui.select(logs, { prompt = "YCM logfile:" }, open)
	end, { nargs = "?" })
end

local function echo_diagnostic()
	if vim.g.ycm_echo_current_diagnostic ~= 1 then
		return
	end
	local values = vim.diagnostic.get(0, {
		namespace = client().diagnostics.namespace,
		lnum = vim.api.nvim_win_get_cursor(0)[1] - 1,
	})
	if values[1] then
		vim.api.nvim_echo({ { values[1].message } }, false, {})
	end
end

local function parse_if_identifier_finished(bufnr)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local before_cursor = vim.api.nvim_get_current_line():sub(1, cursor[2])
	if before_cursor == "" then
		return
	end
	local last_character = vim.fn.strcharpart(before_cursor, vim.fn.strchars(before_cursor) - 1, 1)
	if vim.fn.matchstr(last_character, "\\k") == "" then
		client():parse(bufnr, false)
	end
end

local function setup_autocommands()
	local group = vim.api.nvim_create_augroup("youcompleteme", { clear = true })
	vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
		group = group,
		callback = function(event)
			client():on_buffer_visit(event.buf)
			if vim.g.ycm_auto_trigger ~= 1 and client():is_buffer_allowed(event.buf) then
				vim.bo[event.buf].completefunc = "youcompleteme#CompleteFunc"
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(event)
			if client():is_buffer_allowed(event.buf) then
				client():event("FileSave", event.buf)
				client():parse(event.buf, true)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufUnload", {
		group = group,
		callback = function(event)
			client():event("BufferUnload", event.buf)
			client().buffers[event.buf] = nil
			client().diagnostics:clear(event.buf)
		end,
	})
	vim.api.nvim_create_autocmd("InsertCharPre", {
		group = group,
		callback = function()
			M.last_char_inserted = true
			M.completion_stopped = false
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
		group = group,
		callback = function(event)
			if
				vim.g.ycm_auto_trigger == 1
				and M.last_char_inserted
				and not M.completion_stopped
				and client():is_buffer_allowed(event.buf)
			then
				-- Parsing on identifier boundaries keeps ycmd's identifier database
				-- fresh without reparsing for every inserted character.
				parse_if_identifier_finished(event.buf)
				client():complete(false)
			end
		end,
	})
	vim.api.nvim_create_autocmd("CursorHoldI", {
		group = group,
		callback = function(event)
			client():parse(event.buf, false)
		end,
	})
	vim.api.nvim_create_autocmd("TextChanged", {
		group = group,
		callback = function(event)
			client():parse(event.buf, false)
		end,
	})
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = group,
		callback = function(event)
			client():event("InsertLeave", event.buf)
			client():parse(event.buf, false)
		end,
	})
	vim.api.nvim_create_autocmd("CompleteChanged", {
		group = group,
		callback = function()
			M.last_char_inserted = false
			local item = vim.v.event.completed_item
			if item and not vim.tbl_isempty(item) then
				client():resolve_completion(item)
			end
		end,
	})
	vim.api.nvim_create_autocmd("CompleteDone", {
		group = group,
		callback = function()
			M.last_char_inserted = false
			client():on_complete_done(vim.v.completed_item)
		end,
	})
	vim.api.nvim_create_autocmd("InsertEnter", {
		group = group,
		callback = function()
			M.last_char_inserted = true
		end,
	})
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		callback = echo_diagnostic,
	})
	vim.api.nvim_create_autocmd("CursorHold", {
		group = group,
		callback = function()
			if vim.g.ycm_auto_hover == "CursorHold" then
				client():hover()
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			client():stop()
		end,
	})
end

function M.setup()
	if M.configured then
		return
	end
	M.configured = true
	setup_completeopt()
	setup_mappings()
	setup_commands()
	setup_autocommands()
	client():start()
end

function M.completefunc()
	client():complete(false)
	return -2
end

function M.get_error_count()
	local errors = client():error_counts()
	return errors
end

function M.get_warning_count()
	local _, warnings = client():error_counts()
	return warnings
end

function M.server_pid()
	return client().server.process and client().server.process.pid or -1
end

function M.get_command_response(arguments)
	return client():command_sync(arguments, false)
end

function M.get_command_response_async(callback, arguments, raw)
	client():command(arguments, { raw = true }, function(err, response)
		local value = err and (raw and { error = err } or "") or response
		if not raw and type(value) == "table" then
			value = value.message or value.detailed_info or ""
		end
		vim.fn.call(callback, { value })
	end)
end

function M.get_defined_subcommands()
	return client().subcommands[vim.api.nvim_get_current_buf()] or {}
end

function M.find_symbol(scope)
	local arguments
	if scope == "workspace" then
		local query = vim.fn.input("Workspace symbol: ")
		if query == "" then
			return
		end
		arguments = { "GoToSymbol", query }
	else
		arguments = { "GoToDocumentOutline" }
	end
	client():command(arguments, { raw = true }, function(err, response)
		if err or type(response) ~= "table" then
			return
		end
		-- ycmd returns a location directly for one match and a list when the
		-- query is ambiguous; vim.ui.select always expects a list.
		if response.filepath then
			response = { response }
		elseif not vim.islist(response) then
			return
		end
		vim.ui.select(response, {
			prompt = "YCM symbol:",
			format_item = function(item)
				return item.description or item.name or item.filepath or vim.inspect(item)
			end,
		}, function(selected)
			if selected and selected.filepath then
				local location = selected.location or selected
				location.filepath = location.filepath or selected.filepath
				local path = vim.fn.fnameescape(location.filepath)
				vim.cmd.edit(path)
				if location.line_num then
					vim.api.nvim_win_set_cursor(0, {
						location.line_num,
						math.max(0, (location.column_num or 1) - 1),
					})
				end
			end
		end)
	end)
end

return M
