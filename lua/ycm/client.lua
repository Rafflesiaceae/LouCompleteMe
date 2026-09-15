-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Coordinate native Neovim editor state with the external ycmd server.

local Diagnostics = require("ycm.diagnostics")
local Server = require("ycm.server")
local edits = require("ycm.edits")
local request = require("ycm.request")

local Client = {}
Client.__index = Client

local function notify_error(message)
	vim.notify("YouCompleteMe: " .. tostring(message), vim.log.levels.ERROR)
end

local function error_message(value)
	if type(value) ~= "table" then
		return tostring(value)
	end
	return value.message or (value.exception and value.exception.TYPE) or vim.inspect(value)
end

local function show_errors(response)
	for _, err in ipairs(response and response.errors or {}) do
		notify_error(error_message(err))
	end
end

local function buffer_allowed(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local blocked_buftypes = {
		help = true,
		terminal = true,
		quickfix = true,
		popup = true,
		nofile = true,
	}
	if blocked_buftypes[vim.bo[bufnr].buftype] then
		return false
	end

	local whitelist = vim.g.ycm_filetype_whitelist or { ["*"] = 1 }
	local blacklist = vim.g.ycm_filetype_blacklist or {}
	for _, filetype in ipairs(request.filetypes(bufnr)) do
		local allowed = whitelist["*"] == 1 or whitelist[filetype] == 1
		if whitelist[filetype] == 0 or blacklist[filetype] == 1 then
			allowed = false
		end
		if not allowed then
			return false
		end
	end

	local threshold = tonumber(vim.g.ycm_disable_for_files_larger_than_kb) or 0
	local filepath = request.filepath(bufnr)
	local stat = vim.uv.fs_stat(filepath)
	if threshold > 0 and stat and stat.size > threshold * 1024 then
		return false
	end
	return true
end

local function inside_blocked_syntax()
	local row, column = unpack(vim.api.nvim_win_get_cursor(0))
	if column == 0 then
		return false
	end
	local syntax_id = vim.fn.synID(row, column, 1)
	local name = vim.fn.synIDattr(vim.fn.synIDtrans(syntax_id), "name")
	if name:find("Comment", 1, true) then
		return vim.g.ycm_complete_in_comments ~= 1
	end
	if name:find("String", 1, true) then
		return vim.g.ycm_complete_in_strings ~= 1
	end
	return false
end

local function completion_info(completion)
	local info = completion.detailed_info or ""
	local doc = completion.extra_data and completion.extra_data.doc_string or ""
	if doc ~= "" then
		info = info ~= "" and (info .. "\n" .. doc) or doc
	end
	return info:gsub("%z", "")
end

local function completion_item(completion)
	return {
		word = completion.insertion_text,
		abbr = completion.menu_text or "",
		menu = completion.extra_menu_info or "",
		info = completion_info(completion),
		kind = tostring(completion.kind or ""):sub(1, 1):lower(),
		equal = 1,
		dup = 1,
		empty = 1,
		user_data = vim.json.encode(completion.extra_data or {}),
	}
end

local function overlap_length(left, right)
	local maximum = math.min(#left, #right)
	for length = maximum, 1, -1 do
		if left:sub(#left - length + 1) == right:sub(1, length) then
			return length
		end
	end
	return 0
end

local function adjust_insertions(candidates)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_get_current_line()
	local after = line:sub(cursor[2] + 1)
	if after == "" then
		return candidates
	end
	for _, candidate in ipairs(candidates) do
		local overlap = overlap_length(candidate.word, after)
		if overlap > 0 then
			if candidate.abbr == "" then
				candidate.abbr = candidate.word
			end
			candidate.word = candidate.word:sub(1, #candidate.word - overlap)
		end
	end
	return candidates
end

local default_semantic_triggers = {
	c = { "->", "." },
	cpp = { "->", ".", "::" },
	cs = { "->", ".", "::" },
	cuda = { "->", ".", "::" },
	d = { "." },
	elixir = { "." },
	erlang = { ":" },
	gdscript = { "." },
	go = { "." },
	groovy = { "." },
	java = { "." },
	javascript = { "." },
	javascriptreact = { "." },
	julia = { "." },
	lua = { ".", ":" },
	objc = { "->", "." },
	objcpp = { "->", ".", "::" },
	ocaml = { ".", "#" },
	perl = { "->" },
	perl6 = { "." },
	php = { "->", "::" },
	python = { "." },
	ruby = { ".", "::" },
	rust = { ".", "::" },
	scala = { "." },
	typescript = { "." },
	typescriptreact = { "." },
	vb = { "." },
}

local function filetypes_enabled(bufnr)
	local disabled = vim.g.ycm_filetype_specific_completion_to_disable or {}
	if disabled["*"] == 1 then
		return false
	end
	for _, filetype in ipairs(request.filetypes(bufnr)) do
		if disabled[filetype] == 1 then
			return false
		end
	end
	return true
end

local function trigger_matches(bufnr)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local before_cursor = vim.api.nvim_get_current_line():sub(1, cursor[2])
	local configured = vim.g.ycm_semantic_triggers or {}
	for _, filetype in ipairs(request.filetypes(bufnr)) do
		local triggers = {}
		vim.list_extend(triggers, default_semantic_triggers[filetype] or {})
		vim.list_extend(triggers, configured[filetype] or {})
		for _, trigger in ipairs(triggers) do
			-- Python regular expressions are interpreted by ycmd. The Lua client
			-- handles literal triggers here and leaves regex triggers to ycmd.
			if trigger:sub(1, 3) ~= "re!" and before_cursor:sub(-#trigger) == trigger then
				return true
			end
		end
	end
	return false
end

local function fuzzy_match(candidate, query)
	candidate = candidate:lower()
	query = query:lower()
	local offset = 1
	for index = 1, #query do
		local found = candidate:find(query:sub(index, index), offset, true)
		if not found then
			return false
		end
		offset = found + 1
	end
	return true
end

local function jump_to(location, command, modifiers)
	local filepath = location.filepath
	local escaped = vim.fn.fnameescape(filepath)
	local open_command = command or vim.g.ycm_goto_buffer_command
	if open_command == "same-buffer" then
		open_command = "edit"
	elseif open_command == "new-tab" then
		open_command = "tabedit"
	elseif open_command == "horizontal-split" then
		open_command = "split"
	elseif open_command == "vertical-split" then
		open_command = "vsplit"
	end
	vim.cmd((modifiers and modifiers ~= "" and modifiers .. " " or "") .. open_command .. " " .. escaped)
	if location.line_num then
		pcall(vim.api.nvim_win_set_cursor, 0, {
			location.line_num,
			math.max(0, (location.column_num or 1) - 1),
		})
	end
end

function Client.new()
	return setmetatable({
		server = Server.new(),
		diagnostics = Diagnostics.new(),
		buffers = {},
		completion_request = nil,
		completion_generation = 0,
		last_completion_data = nil,
		last_completion_response = nil,
		message_requests = {},
		subcommands = {},
		available_completers = {},
		omni_cache = nil,
		started = false,
	}, Client)
end

function Client:start(callback)
	if self.started then
		if callback then
			callback()
		end
		return
	end
	self.started = true
	self.server:start(function(err)
		if err then
			self.started = false
			notify_error(err)
			if callback then
				callback(err)
			end
			return
		end
		self:on_buffer_visit(vim.api.nvim_get_current_buf())
		if callback then
			callback()
		end
	end)
end

function Client:stop()
	self.started = false
	self.server:stop()
end

function Client:restart()
	vim.notify("Restarting ycmd server...")
	self.message_requests = {}
	self.server:restart(function(err)
		if err then
			notify_error(err)
			return
		end
		self:on_buffer_visit(vim.api.nvim_get_current_buf())
	end)
end

function Client:request(handler, data, options, callback)
	options = options or {}
	return self.server:request(handler, data, options, function(err, response)
		if err and not options.quiet and err ~= "Request cancelled" then
			notify_error(err)
		end
		callback(err, response)
	end)
end

function Client:request_sync(handler, data, options)
	local finished = false
	local request_err
	local response
	self:request(handler, data, options or {}, function(err, value)
		request_err = err
		response = value
		finished = true
	end)
	vim.wait((options and options.timeout or 30000) + 100, function()
		return finished
	end, 10)
	return request_err, response
end

function Client:event(name, bufnr, extra, callback)
	if not self.server.ready then
		return
	end
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, data = pcall(request.build, bufnr)
	if not ok then
		return
	end
	data.event_name = name
	if extra then
		data = vim.tbl_extend("force", data, extra)
	end
	self:request("event_notification", data, { quiet = true }, callback or function() end)
end

function Client:_buffer_state(bufnr)
	if not self.buffers[bufnr] then
		self.buffers[bufnr] = {
			parsed_tick = -1,
			parse_request = nil,
			resend_parse = false,
		}
	end
	return self.buffers[bufnr]
end

function Client:parse(bufnr, force, callback)
	callback = callback or function() end
	if not self.server.ready or not buffer_allowed(bufnr) then
		callback("buffer is not available for parsing")
		return
	end
	local state = self:_buffer_state(bufnr)
	local tick = vim.b[bufnr].changedtick or 0
	if not force and state.parsed_tick == tick then
		callback()
		return
	end
	if state.parse_request then
		state.resend_parse = true
		callback()
		return
	end

	local data = request.build(bufnr)
	request.add_extra_conf_data(data)
	request.add_tags(data)
	data.event_name = "FileReadyToParse"
	state.parsed_tick = tick
	state.parse_request = self:request("event_notification", data, {}, function(err, response)
		state.parse_request = nil
		if not err then
			self.diagnostics:update(bufnr, response or {}, vim.g.ycm_open_loclist_on_ycm_diags == 1)
		end
		local resend = state.resend_parse or state.parsed_tick ~= (vim.b[bufnr].changedtick or 0)
		state.resend_parse = false
		callback(err)
		if resend then
			self:parse(bufnr, true)
		end
	end)
end

function Client:_start_messages(bufnr)
	for _, filetype in ipairs(request.filetypes(bufnr)) do
		if not self.message_requests[filetype] then
			local token = {}
			self.message_requests[filetype] = token
			local function poll()
				if
					self.message_requests[filetype] ~= token
					or not self.server.ready
					or not vim.api.nvim_buf_is_valid(bufnr)
				then
					return
				end
				local data = request.build(bufnr)
				self:request("receive_messages", data, {
					quiet = true,
					timeout = 65000,
				}, function(err, response)
					if err then
						self.message_requests[filetype] = nil
						return
					end
					if response == false then
						self.message_requests[filetype] = nil
						return
					end
					if type(response) == "table" then
						for _, notification in ipairs(response) do
							if notification.message then
								vim.notify(notification.message)
							elseif notification.diagnostics and notification.filepath then
								self.diagnostics:update_for_file(notification.filepath, notification.diagnostics)
							end
						end
					end
					poll()
				end)
			end
			poll()
		end
	end
end

function Client:on_buffer_visit(bufnr)
	if not self.server.ready or not buffer_allowed(bufnr) then
		return
	end
	vim.b[bufnr].ycm_completing = 1
	self:event("BufferVisit", bufnr, request.add_ultisnips_data({}))
	self:_check_completer_availability(bufnr)
	self:_start_messages(bufnr)
	self:parse(bufnr, true)
	self:defined_subcommands(function(_, commands)
		self.subcommands[bufnr] = commands or {}
	end)
end

function Client:_check_completer_availability(bufnr)
	for _, filetype in ipairs(request.filetypes(bufnr)) do
		if self.available_completers[filetype] == nil then
			-- FileType and BufEnter may fire back-to-back. Mark this request as
			-- pending so only one availability check is sent for each filetype.
			self.available_completers[filetype] = "pending"
			local data = request.build(bufnr)
			data.filetypes = { filetype }
			self:request("semantic_completion_available", data, { quiet = true }, function(err, available)
				self.available_completers[filetype] = not err and available == true
			end)
		end
	end
end

function Client:_native_completer_usable(bufnr)
	if not filetypes_enabled(bufnr) then
		return false
	end
	for _, filetype in ipairs(request.filetypes(bufnr)) do
		if self.available_completers[filetype] == true then
			return true
		end
	end
	return false
end

function Client:_omnifunc_completion(bufnr, force_semantic)
	local omnifunc = vim.bo[bufnr].omnifunc
	if omnifunc == "" or not filetypes_enabled(bufnr) then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_get_current_line()
	local cache = self.omni_cache
	local use_cache = not force_semantic
		and vim.g.ycm_cache_omnifunc == 1
		and cache
		and cache.bufnr == bufnr
		and cache.row == cursor[1]
		and cursor[2] >= cache.start_column
		and line:sub(1, cache.start_column) == cache.prefix
	if not use_cache and not force_semantic and not trigger_matches(bufnr) then
		self.omni_cache = nil
		return false
	end

	local start_column
	local items
	local ok = true
	local omni_err
	if use_cache then
		start_column = cache.start_column
		items = vim.deepcopy(cache.items)
	else
		ok, omni_err = pcall(function()
			start_column = tonumber(vim.fn[omnifunc](1, ""))
			if start_column == -3 or start_column == -2 then
				items = {}
				return
			end
			if not start_column or start_column < 0 or start_column > cursor[2] then
				start_column = cursor[2]
			end

			local query = line:sub(start_column + 1, cursor[2])
			vim.api.nvim_win_set_cursor(0, { cursor[1], start_column })
			items = vim.fn[omnifunc](0, query)
			if type(items) == "table" and items.words then
				items = items.words
			end
			if type(items) ~= "table" then
				error('omnifunc must return a list or a dictionary with a "words" list')
			end
		end)
	end
	vim.api.nvim_win_set_cursor(0, cursor)
	if not ok then
		notify_error("Omnifunc returned a bad value: " .. tostring(omni_err))
		return true
	end

	local candidates = {}
	local query = line:sub(start_column + 1, cursor[2])
	for _, item in ipairs(items) do
		local word = type(item) == "table" and item.word or tostring(item)
		if fuzzy_match(tostring(word or ""), query) then
			if type(item) == "table" then
				item = vim.deepcopy(item)
				item.equal = 1
				candidates[#candidates + 1] = item
			else
				candidates[#candidates + 1] = { word = tostring(item), equal = 1 }
			end
		end
	end
	if not use_cache and vim.g.ycm_cache_omnifunc == 1 then
		self.omni_cache = {
			bufnr = bufnr,
			row = cursor[1],
			start_column = start_column,
			prefix = line:sub(1, start_column),
			items = vim.deepcopy(items),
		}
	end
	self.last_completion_response = {
		completions = vim.deepcopy(candidates),
		completion_start_column = start_column + 1,
	}
	if #candidates > 0 and vim.api.nvim_get_mode().mode:match("^[iR]") then
		local complete_ok, complete_err = pcall(vim.fn.complete, start_column + 1, candidates)
		if not complete_ok then
			notify_error(complete_err)
		end
	end
	return true
end

function Client:complete(force_semantic)
	local bufnr = vim.api.nvim_get_current_buf()
	if not self.server.ready or not buffer_allowed(bufnr) or inside_blocked_syntax() then
		return
	end
	local line = vim.api.nvim_get_current_line()
	if line:match("^%s*$") then
		return
	end
	if not self:_native_completer_usable(bufnr) and self:_omnifunc_completion(bufnr, force_semantic) then
		return
	end

	self.completion_generation = self.completion_generation + 1
	local generation = self.completion_generation
	if self.completion_request then
		self.completion_request.cancel()
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local tick = vim.b.changedtick
	local data = request.add_extra_conf_data(request.build(bufnr))
	data.force_semantic = force_semantic == true
	self.last_completion_data = data

	self.completion_request = self:request("completions", data, { quiet = true }, function(err, response)
		if generation ~= self.completion_generation then
			return
		end
		self.completion_request = nil
		if err or not response then
			if err and err ~= "Request cancelled" then
				notify_error(err)
			end
			return
		end
		show_errors(response)
		self.last_completion_response = response
		if
			vim.api.nvim_get_current_buf() ~= bufnr
			or vim.b.changedtick ~= tick
			or vim.api.nvim_win_get_cursor(0)[1] ~= cursor[1]
			or vim.api.nvim_win_get_cursor(0)[2] ~= cursor[2]
			or not vim.api.nvim_get_mode().mode:match("^[iR]")
		then
			return
		end
		local candidates = {}
		for _, completion in ipairs(response.completions or {}) do
			candidates[#candidates + 1] = completion_item(completion)
		end
		adjust_insertions(candidates)
		if #candidates > 0 then
			local start_column = tonumber(response.completion_start_column) or cursor[2] + 1
			local completeopt = vim.bo.completeopt
			if not completeopt:find("noselect", 1, true) then
				vim.bo.completeopt = completeopt .. ",noselect"
			end
			local ok, complete_err = pcall(vim.fn.complete, start_column, candidates)
			vim.bo.completeopt = completeopt
			if not ok then
				notify_error(complete_err)
			end
		end
	end)
end

function Client:resolve_completion(item)
	if not self.last_completion_data or not item or not item.user_data then
		return
	end
	local ok, extra = pcall(vim.json.decode, item.user_data)
	if not ok or type(extra) ~= "table" or not extra.resolve then
		return
	end
	local data = vim.deepcopy(self.last_completion_data)
	data.resolve = extra.resolve
	self:request("resolve_completion", data, { quiet = true }, function(err, response)
		if err or not response or not response.completion then
			return
		end
		show_errors(response)
		local resolved = completion_item(response.completion)
		if resolved.info ~= "" then
			vim.lsp.util.open_floating_preview(
				vim.split(resolved.info, "\n", { plain = true }),
				"markdown",
				{ focus = false, border = "single" }
			)
		end
	end)
end

function Client:on_complete_done(item)
	if not item or not item.user_data or item.user_data == "" then
		return
	end
	local ok, extra = pcall(vim.json.decode, item.user_data)
	if not ok or type(extra) ~= "table" then
		return
	end
	if extra.fixits and #extra.fixits > 0 then
		edits.apply(extra.fixits[1].chunks, { silent = true })
	end
end

function Client:_command_data(arguments, command_options)
	local bufnr = vim.api.nvim_get_current_buf()
	local data = request.build(bufnr)
	data.options = {
		tab_size = vim.bo.shiftwidth,
		insert_spaces = vim.bo.expandtab,
	}
	local final_arguments = {}
	for _, argument in ipairs(arguments) do
		if argument:sub(1, 3) == "ft=" then
			data.completer_target = argument:sub(4)
		elseif argument:match("^%-%-bufnr=") then
			local requested = tonumber(argument:match("^%-%-bufnr=(%d+)$"))
			if requested then
				bufnr = requested
				data = vim.tbl_extend("force", request.build(bufnr), {
					options = data.options,
				})
			end
		else
			final_arguments[#final_arguments + 1] = argument
		end
	end
	if final_arguments[1] == "GoToDefinitionElseDeclaration" then
		final_arguments[1] = "GoTo"
	end
	data.command_arguments = final_arguments
	if command_options and command_options.range then
		data = vim.tbl_extend("force", data, request.range(command_options.line1, command_options.line2))
	end
	request.add_extra_conf_data(data)
	return data
end

function Client:_handle_command_response(response, options)
	if response == nil or response == vim.NIL then
		return
	end
	if type(response) ~= "table" then
		vim.notify(tostring(response))
	elseif response.fixits then
		local fixits = response.fixits
		if #fixits == 0 then
			vim.notify("No fixits found for current line")
			return
		end
		local function apply_fixit(fixit)
			if fixit.resolve then
				local data = vim.deepcopy(options.request_data)
				data.fixit = fixit
				self:request("resolve_fixit", data, {}, function(err, resolved)
					if not err and resolved and resolved.fixits and resolved.fixits[1] then
						edits.apply(resolved.fixits[1].chunks, {
							silent = options.command == "Format",
						})
					end
				end)
			else
				edits.apply(fixit.chunks, { silent = options.command == "Format" })
			end
		end
		if #fixits == 1 then
			apply_fixit(fixits[1])
		else
			vim.ui.select(fixits, {
				prompt = "FixIt suggestion:",
				format_item = function(fixit)
					return fixit.text or "FixIt"
				end,
			}, function(selected)
				if selected then
					apply_fixit(selected)
				end
			end)
		end
	elseif response.message then
		vim.notify(response.message)
	elseif response.detailed_info then
		vim.lsp.util.open_floating_preview(
			vim.split(response.detailed_info, "\n", { plain = true }),
			"markdown",
			{ focus = true, border = "single" }
		)
	elseif vim.tbl_islist(response) then
		local items = {}
		for _, location in ipairs(response) do
			items[#items + 1] = {
				filename = location.filepath,
				lnum = location.line_num,
				col = location.column_num,
				text = location.description or "",
			}
		end
		vim.fn.setqflist({}, "r", { title = "YCM locations", items = items })
		vim.cmd.copen()
	elseif response.filepath then
		jump_to(response, options.buffer_command, options.modifiers)
	else
		vim.notify(vim.inspect(response))
	end
end

function Client:command(arguments, options, callback)
	options = options or {}
	local data = self:_command_data(arguments, options)
	options.request_data = data
	options.command = data.command_arguments[1]
	self:request("run_completer_command", data, {}, function(err, response)
		if not err and not options.raw then
			self:_handle_command_response(response, options)
		end
		if callback then
			callback(err, response)
		end
	end)
end

function Client:command_sync(arguments, raw)
	local data = self:_command_data(arguments)
	local err, response = self:request_sync("run_completer_command", data)
	if err then
		return raw and { error = err } or ""
	end
	if raw then
		return response
	end
	if type(response) == "string" or type(response) == "number" or type(response) == "boolean" then
		return tostring(response)
	end
	if type(response) == "table" then
		return response.message or response.detailed_info or ""
	end
	return ""
end

function Client:defined_subcommands(callback)
	local data = request.build()
	self:request("defined_subcommands", data, { quiet = true }, callback)
end

function Client:debug_info()
	local data = request.add_extra_conf_data(request.build())
	self:request("debug_info", data, {}, function(err, response)
		if err then
			return
		end
		local lines = {
			"YouCompleteMe debug information:",
			"  Client: native Neovim Lua",
			"  Python provider required: no",
			("  Server: http://127.0.0.1:%d"):format(self.server.port),
			("  Server PID: %d"):format(self.server.process.pid),
			"  Server stdout: " .. self.server.stdout_log,
			"  Server stderr: " .. self.server.stderr_log,
		}
		if response and response.python then
			lines[#lines + 1] = "  Server Python: " .. response.python.executable
			lines[#lines + 1] = "  Server Python version: " .. response.python.version
		end
		if response and response.clang then
			lines[#lines + 1] = "  Clang support: " .. tostring(response.clang.has_support)
			lines[#lines + 1] = "  Clang version: " .. tostring(response.clang.version)
		end
		vim.notify(table.concat(lines, "\n"))
	end)
end

function Client:force_diagnostics(open_location_list)
	local bufnr = vim.api.nvim_get_current_buf()
	self:parse(bufnr, true, function(err)
		if err then
			return
		end
		local values = vim.diagnostic.get(bufnr, {
			namespace = self.diagnostics.namespace,
		})
		if #values == 0 then
			vim.notify("No warnings or errors detected.")
		elseif open_location_list then
			vim.diagnostic.setloclist({
				namespace = self.diagnostics.namespace,
				open = true,
			})
		end
	end)
end

function Client:hover()
	local commands = self.subcommands[vim.api.nvim_get_current_buf()] or {}
	local command
	for _, candidate in ipairs({ "GetHover", "GetDoc", "GetType" }) do
		if vim.tbl_contains(commands, candidate) then
			command = candidate
			break
		end
	end
	if command then
		self:command({ command }, {})
	end
end

function Client:error_counts()
	return self.diagnostics:counts(vim.api.nvim_get_current_buf())
end

function Client:is_buffer_allowed(bufnr)
	return buffer_allowed(bufnr)
end

return Client
