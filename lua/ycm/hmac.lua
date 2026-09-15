-- Copyright (C) 2026 YouCompleteMe contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Implement the nested HMAC-SHA256 scheme used by ycmd's HTTP API.

local M = {}

local BLOCK_SIZE = 64
local bit = require("bit")

local function sha256(value)
	return vim.text.hexdecode(vim.fn.sha256(value))
end

function M.digest(value, secret)
	if #secret > BLOCK_SIZE then
		secret = sha256(secret)
	end
	secret = secret .. string.rep("\0", BLOCK_SIZE - #secret)

	local outer = {}
	local inner = {}
	for index = 1, BLOCK_SIZE do
		local byte = secret:byte(index)
		outer[index] = string.char(bit.bxor(byte, 0x5c))
		inner[index] = string.char(bit.bxor(byte, 0x36))
	end

	return sha256(table.concat(outer) .. sha256(table.concat(inner) .. value))
end

function M.request_digest(method, path, body, secret)
	local pieces = M.digest(method, secret) .. M.digest(path, secret) .. M.digest(body or "", secret)
	return M.digest(pieces, secret)
end

function M.request_header(method, path, body, secret)
	return vim.base64.encode(M.request_digest(method, path, body, secret))
end

function M.valid_response(body, header, secret)
	if not header then
		return false
	end
	local ok, expected = pcall(vim.base64.decode, header)
	if not ok or #expected ~= 32 then
		return false
	end
	local actual = M.digest(body, secret)
	local difference = 0
	for index = 1, #actual do
		difference = bit.bor(difference, bit.bxor(actual:byte(index), expected:byte(index)))
	end
	return difference == 0
end

return M
