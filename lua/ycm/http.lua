-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Provide an asynchronous authenticated HTTP client without external tools.

local hmac = require("ycm.hmac")

local M = {}

local function close_handle(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

local function parse_headers(block)
	local lines = vim.split(block, "\r\n", { plain = true })
	local status = tonumber((lines[1] or ""):match("^HTTP/%d%.%d%s+(%d+)"))
	local headers = {}
	for index = 2, #lines do
		local name, value = lines[index]:match("^([^:]+):%s*(.*)$")
		if name then
			headers[name:lower()] = value
		end
	end
	return status, headers
end

local function decode_chunked(body)
	local result = {}
	local offset = 1
	while true do
		local line_end = body:find("\r\n", offset, true)
		if not line_end then
			return nil
		end
		local size = tonumber(body:sub(offset, line_end - 1):match("^%s*([%da-fA-F]+)"), 16)
		if not size then
			return nil, "Malformed chunked HTTP response"
		end
		offset = line_end + 2
		if size == 0 then
			return table.concat(result)
		end
		if #body < offset + size + 1 then
			return nil
		end
		result[#result + 1] = body:sub(offset, offset + size - 1)
		if body:sub(offset + size, offset + size + 1) ~= "\r\n" then
			return nil, "Malformed chunked HTTP response"
		end
		offset = offset + size + 2
	end
end

function M.request(options, callback)
	local method = options.method or "GET"
	local path = options.path
	local body = options.body or ""
	local port = assert(options.port, "Missing ycmd port")
	local secret = assert(options.secret, "Missing ycmd HMAC secret")
	local tcp = vim.uv.new_tcp()
	local timer = vim.uv.new_timer()
	local chunks = {}
	local done = false
	local request_headers = {
		("%s %s HTTP/1.1"):format(method, path),
		("Host: 127.0.0.1:%d"):format(port),
		"Accept: application/json",
		"Content-Type: application/json",
		"Connection: close",
		"x-ycm-hmac: " .. hmac.request_header(method, path:match("^[^?]*"), body, secret),
		"Content-Length: " .. #body,
		"",
		body,
	}
	local encoded_request = table.concat(request_headers, "\r\n")

	local function finish(err, response)
		if done then
			return
		end
		done = true
		if tcp and not tcp:is_closing() then
			tcp:read_stop()
		end
		close_handle(tcp)
		close_handle(timer)
		vim.schedule(function()
			callback(err, response)
		end)
	end

	local function try_response(at_eof)
		local raw = table.concat(chunks)
		local header_end = raw:find("\r\n\r\n", 1, true)
		if not header_end then
			if at_eof then
				finish("Incomplete HTTP response from ycmd")
			end
			return
		end

		local status, headers = parse_headers(raw:sub(1, header_end - 1))
		if not status then
			finish("Malformed HTTP response from ycmd")
			return
		end

		local response_body = raw:sub(header_end + 4)
		local content_length = tonumber(headers["content-length"])
		if content_length and #response_body < content_length and not at_eof then
			return
		end
		if content_length then
			response_body = response_body:sub(1, content_length)
		elseif headers["transfer-encoding"] and headers["transfer-encoding"]:lower():find("chunked", 1, true) then
			local decoded, decode_err = decode_chunked(response_body)
			if not decoded then
				if decode_err or at_eof then
					finish(decode_err or "Incomplete chunked HTTP response from ycmd")
				end
				return
			end
			response_body = decoded
		elseif not at_eof then
			return
		end

		finish(nil, {
			status = status,
			headers = headers,
			body = response_body,
		})
	end

	local timeout = options.timeout or 30000
	timer:start(timeout, 0, function()
		finish(("ycmd request timed out after %d ms"):format(timeout))
	end)

	tcp:connect("127.0.0.1", port, function(connect_err)
		if connect_err then
			finish("Unable to connect to ycmd: " .. connect_err)
			return
		end

		tcp:write(encoded_request, function(write_err)
			if write_err then
				finish("Unable to write ycmd request: " .. write_err)
			end
		end)

		tcp:read_start(function(read_err, chunk)
			if read_err then
				finish("Unable to read ycmd response: " .. read_err)
				return
			end
			if chunk then
				chunks[#chunks + 1] = chunk
				try_response(false)
			else
				try_response(true)
			end
		end)
	end)

	return {
		cancel = function()
			finish("Request cancelled")
		end,
	}
end

function M.json_request(options, callback)
	local body = options.data == nil and "" or vim.json.encode(options.data)
	options.body = body
	options.method = options.method or (options.data == nil and "GET" or "POST")
	return M.request(options, function(err, response)
		if err then
			callback(err)
			return
		end
		-- Authenticate empty responses as well; otherwise a peer could forge a
		-- successful response simply by omitting both the body and HMAC header.
		if not hmac.valid_response(response.body, response.headers["x-ycm-hmac"], options.secret) then
			callback("Received invalid HMAC for ycmd response")
			return
		end

		local data
		if response.body ~= "" then
			local ok, decoded = pcall(vim.json.decode, response.body)
			if not ok then
				callback("Invalid JSON response from ycmd: " .. decoded)
				return
			end
			data = decoded
		end
		callback(nil, data, response.status)
	end)
end

return M
