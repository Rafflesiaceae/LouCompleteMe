-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Own the external ycmd process and its authenticated request lifecycle.

local http = require("ycm.http")

local Server = {}
Server.__index = Server

local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function read_file(path)
	local descriptor = vim.uv.fs_open(path, "r", 438)
	if not descriptor then
		return nil
	end
	local stat = vim.uv.fs_fstat(descriptor)
	local contents = stat and vim.uv.fs_read(descriptor, stat.size, 0) or nil
	vim.uv.fs_close(descriptor)
	return contents
end

local function write_file(path, contents)
	local descriptor, err = vim.uv.fs_open(path, "w", 384)
	if not descriptor then
		return nil, err
	end
	local written, write_err = vim.uv.fs_write(descriptor, contents, 0)
	vim.uv.fs_close(descriptor)
	return written, write_err
end

local function executable(value)
	if not value or value == "" then
		return nil
	end
	if vim.fn.executable(value) == 1 then
		return vim.fn.exepath(value) ~= "" and vim.fn.exepath(value) or value
	end
	return nil
end

local function python_interpreter(root)
	local configured = executable(vim.g.ycm_server_python_interpreter)
	if configured then
		return configured
	end

	local built_with = read_file(root .. "/third_party/ycmd/PYTHON_USED_DURING_BUILDING")
	if built_with then
		built_with = built_with:gsub("%s+$", "")
		local interpreter = executable(built_with)
		if interpreter then
			return interpreter
		end
	end

	return executable("python3") or executable("python")
end

local function user_options(root, overrides)
	local defaults = read_file(root .. "/third_party/ycmd/ycmd/default_settings.json")
	local options = {}
	if defaults then
		local ok, decoded = pcall(vim.json.decode, defaults)
		if ok then
			options = decoded
		end
	end

	for _, global_name in ipairs(vim.fn.eval("keys(g:)")) do
		if global_name:sub(1, 4) == "ycm_" then
			local ok, value = pcall(vim.api.nvim_get_var, global_name)
			if ok then
				options[global_name:sub(5)] = value
			end
		end
	end
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	return options
end

local function unused_port()
	local socket, socket_err = vim.uv.new_tcp()
	if not socket then
		return nil, socket_err
	end
	local bound, bind_err = socket:bind("127.0.0.1", 0)
	if not bound then
		socket:close()
		return nil, bind_err
	end
	local address, address_err = socket:getsockname()
	socket:close()
	return address and address.port or nil, address_err
end

local function remove_file(path)
	if path and path ~= "" then
		vim.uv.fs_unlink(path)
	end
end

function Server.new(options)
	return setmetatable({
		root = plugin_root(),
		default_options = options or {},
		generation = 0,
		ready = false,
		stopping = false,
		process = nil,
		exit = nil,
		keepalive = nil,
		pending = {},
	}, Server)
end

function Server:is_alive()
	return self.process ~= nil and self.exit == nil
end

function Server:start(callback)
	self.generation = self.generation + 1
	local generation = self.generation
	self.ready = false
	self.stopping = false
	self.exit = nil
	self.options = user_options(self.root, self.default_options)

	local interpreter = python_interpreter(self.root)
	local server_script = self.root .. "/third_party/ycmd/ycmd"
	if not interpreter then
		callback("Unable to find Python for the external ycmd server. Set " .. "g:ycm_server_python_interpreter.")
		return
	end
	if vim.uv.fs_stat(server_script) == nil then
		callback("Unable to find ycmd. Run git submodule update --init --recursive.")
		return
	end

	local secret, random_err = vim.uv.random(16)
	if not secret then
		callback("Unable to generate the ycmd HMAC secret: " .. random_err)
		return
	end
	local port, port_err = unused_port()
	if not port then
		callback("Unable to allocate a localhost port for ycmd: " .. port_err)
		return
	end
	self.secret = secret
	self.port = port
	self.options.hmac_secret = vim.base64.encode(self.secret)
	self.options.server_keep_logfiles = self.options.keep_logfiles or 0

	self.options_file = vim.fn.tempname() .. "_ycm_options.json"
	local _, write_err = write_file(self.options_file, vim.json.encode(self.options))
	if write_err then
		callback("Unable to write ycmd options: " .. write_err)
		return
	end

	self.stdout_log = vim.fn.tempname() .. "_ycmd_stdout.log"
	self.stderr_log = vim.fn.tempname() .. "_ycmd_stderr.log"
	local command = {
		interpreter,
		server_script,
		"--port=" .. self.port,
		"--options_file=" .. self.options_file,
		"--log=" .. (self.options.log_level or "info"),
		"--idle_suicide_seconds=1800",
		"--stdout=" .. self.stdout_log,
		"--stderr=" .. self.stderr_log,
	}
	if self.options.keep_logfiles == 1 then
		command[#command + 1] = "--keep_logfiles"
	end

	local ok, process = pcall(vim.system, command, {
		stdin = true,
		stdout = function() end,
		stderr = function() end,
	}, function(result)
		vim.schedule(function()
			if self.generation ~= generation then
				return
			end
			self.exit = result
			self.ready = false
			if not self.stopping then
				vim.notify(
					("The ycmd server shut down with exit code %d. See %s."):format(result.code, self.stderr_log),
					vim.log.levels.ERROR
				)
			end
		end)
	end)
	if not ok then
		remove_file(self.options_file)
		callback("Unable to start ycmd: " .. process)
		return
	end
	self.process = process

	local attempts = 0
	local function wait_until_ready()
		if self.generation ~= generation then
			return
		end
		if not self:is_alive() then
			callback("The ycmd server exited before becoming ready.")
			return
		end
		attempts = attempts + 1
		self:request("ready", nil, { method = "GET", quiet = true }, function(err, data)
			if not err and data == true then
				self.ready = true
				-- ycmd has consumed its startup options by the time it reports ready.
				remove_file(self.options_file)
				self.options_file = nil
				self:_start_keepalive()
				callback()
			elseif attempts < 300 then
				vim.defer_fn(wait_until_ready, 100)
			else
				callback(err or "Timed out waiting for ycmd to become ready.")
			end
		end)
	end
	vim.defer_fn(wait_until_ready, 20)
end

function Server:_start_keepalive()
	if self.keepalive and not self.keepalive:is_closing() then
		self.keepalive:stop()
		self.keepalive:close()
	end
	self.keepalive = vim.uv.new_timer()
	self.keepalive:start(
		600000,
		600000,
		vim.schedule_wrap(function()
			if self.ready then
				self:request("healthy", nil, { method = "GET", quiet = true }, function() end)
			end
		end)
	)
	self.keepalive:unref()
end

function Server:request(handler, data, options, callback)
	options = options or {}
	if not self:is_alive() then
		vim.schedule(function()
			callback("ycmd is not running")
		end)
		return { cancel = function() end }
	end

	local path = "/" .. handler
	if options.query then
		local query = {}
		for key, value in pairs(options.query) do
			query[#query + 1] = vim.uri_encode(tostring(key)) .. "=" .. vim.uri_encode(tostring(value))
		end
		table.sort(query)
		path = path .. "?" .. table.concat(query, "&")
	end

	local request
	request = http.json_request({
		port = self.port,
		secret = self.secret,
		path = path,
		method = options.method,
		data = data,
		timeout = options.timeout,
	}, function(err, response, status)
		self.pending[request] = nil
		if err then
			callback(err)
			return
		end

		if status == 500 then
			local exception = response and response.exception or {}
			if exception.TYPE == "UnknownExtraConf" and not options.no_retry then
				local load = vim.fn.confirm(response.message or "Load extra config?", "&Load\n&Ignore", 1) == 1
				self:request(
					load and "load_extra_conf_file" or "ignore_extra_conf_file",
					{ filepath = exception.extra_conf_file },
					{ no_retry = true },
					function(config_err)
						if config_err then
							callback(config_err)
							return
						end
						local retried = vim.tbl_extend("force", options, { no_retry = true })
						self:request(handler, data, retried, callback)
					end
				)
				return
			end
			callback(response and response.message or "ycmd returned an error")
			return
		end
		if status < 200 or status >= 300 then
			callback(("ycmd returned HTTP %d"):format(status))
			return
		end
		callback(nil, response)
	end)
	self.pending[request] = true
	return request
end

function Server:stop()
	self.stopping = true
	self.ready = false
	if self.keepalive and not self.keepalive:is_closing() then
		self.keepalive:stop()
		self.keepalive:close()
	end
	for request in pairs(self.pending) do
		request.cancel()
	end
	self.pending = {}
	if self:is_alive() then
		self:request("shutdown", {}, { quiet = true, timeout = 500 }, function() end)
		local process = self.process
		vim.defer_fn(function()
			if self:is_alive() and process == self.process then
				process:kill(15)
			end
		end, 750)
	end
	remove_file(self.options_file)
	self.options_file = nil
end

function Server:restart(callback)
	self:stop()
	self.process = nil
	self.exit = nil
	vim.defer_fn(function()
		self:start(callback)
	end, 100)
end

return Server
