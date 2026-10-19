local root = vim.env.YCM_TEST_ROOT
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/test/neovim/runtime")

assert(vim.fn.has("python3") == 0, "the Neovim tests must run without a Python provider")

local function equal(expected, actual, context)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual:   %s"):format(
				context or "values differ",
				vim.inspect(expected),
				vim.inspect(actual)
			)
		)
	end
end

local hmac = require("ycm.hmac")
local secret = "0123456789abcdef"
equal(
	"oWHp+VeRhHx6ZmuKVZhOG91fELg5N1gX2RMyhm2JU+c=",
	hmac.request_header("POST", "/completions", '{"x":1}', secret),
	"request HMAC must match ycmd"
)
equal(
	true,
	hmac.valid_response("response", vim.base64.encode(hmac.digest("response", secret)), secret),
	"response HMAC must validate"
)
equal(
	false,
	hmac.valid_response("tampered", vim.base64.encode(hmac.digest("response", secret)), secret),
	"tampered response must not validate"
)

local request = require("ycm.request")
local first = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(first, "/tmp/ycm-lua-request.cpp")
vim.bo[first].filetype = "cpp"
vim.api.nvim_buf_set_lines(first, 0, -1, true, { "int café;", "cafe" })
vim.api.nvim_win_set_cursor(0, { 2, 3 })

local second = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(second, "/tmp/ycm-lua-other.cpp")
vim.bo[second].filetype = "cpp"
vim.api.nvim_buf_set_lines(second, 0, -1, true, { "int otherBuffer;" })

local data = request.build(first)
equal(2, data.line_num, "line is one-based")
equal(4, data.column_num, "column is one-based byte offset")
equal(
	"int café;\ncafe\n",
	data.file_data[data.filepath].contents,
	"current buffer is serialized with trailing newline"
)
equal("int otherBuffer;\n", data.file_data["/tmp/ycm-lua-other.cpp"].contents, "other modified buffers are included")

local Diagnostics = require("ycm.diagnostics")
vim.g.ycm_show_diagnostics_ui = 1
vim.g.ycm_enable_diagnostic_highlighting = 1
vim.g.ycm_enable_diagnostic_signs = 1
vim.g.ycm_update_diagnostics_in_insert_mode = 1
vim.g.ycm_max_diagnostics_to_display = 30
vim.g.ycm_filter_diagnostics = {}
local diagnostics = Diagnostics.new()
diagnostics:update(first, {
	{
		kind = "ERROR",
		text = "broken",
		location = { line_num = 1, column_num = 5 },
		location_extent = {
			start = { line_num = 1, column_num = 5 },
			["end"] = { line_num = 1, column_num = 9 },
		},
	},
}, false)
local rendered = vim.diagnostic.get(first, { namespace = diagnostics.namespace })
equal(1, #rendered, "one diagnostic is rendered")
equal(0, rendered[1].lnum, "diagnostic line is zero-based for Neovim")
equal(4, rendered[1].col, "diagnostic column is zero-based for Neovim")

local edits = require("ycm.edits")
edits.apply({
	{
		range = {
			start = { filepath = data.filepath, line_num = 2, column_num = 1 },
			["end"] = { filepath = data.filepath, line_num = 2, column_num = 5 },
		},
		replacement_text = "café",
	},
}, { silent = true })
equal("café", vim.api.nvim_buf_get_lines(first, 1, 2, true)[1], "fixit edit uses ycmd byte ranges")

vim.cmd([[
  function! YcmTestOmnifunc(findstart, base) abort
    if a:findstart
      return 4
    endif
    return [ {'word': 'alpha'}, 'beta' ]
  endfunction
]])
vim.g.ycm_cache_omnifunc = 1
vim.g.ycm_semantic_triggers = { cpp = { "." } }
vim.g.ycm_filetype_specific_completion_to_disable = {}
vim.g.ycm_use_ultisnips_completer = 1
vim.bo[first].omnifunc = "YcmTestOmnifunc"
vim.api.nvim_set_current_buf(first)
vim.api.nvim_buf_set_lines(first, 0, -1, true, { "obj." })
vim.o.virtualedit = "onemore"
vim.api.nvim_win_set_cursor(0, { 1, 4 })

local Client = require("ycm.client")
local client = Client.new()
equal(true, client:_omnifunc_completion(first, false), "literal semantic trigger invokes omnifunc")
equal(2, #client.last_completion_response.completions, "omnifunc strings and dictionaries are accepted")
equal(5, client.last_completion_response.completion_start_column, "omnifunc start column is converted to Vim indexing")
equal({ 1, 4 }, vim.api.nvim_win_get_cursor(0), "omnifunc restores the cursor")

vim.api.nvim_buf_set_lines(first, 0, -1, true, { "obj.al" })
vim.api.nvim_win_set_cursor(0, { 1, 6 })
equal(true, client:_omnifunc_completion(first, false), "omnifunc cache remains active after the trigger")
equal(1, #client.last_completion_response.completions, "cached omnifunc candidates are fuzzy-filtered")
equal("alpha", client.last_completion_response.completions[1].word, "cached omnifunc returns the matching item")

client.omni_cache = nil
vim.bo[first].filetype = "ycmtest"
vim.bo[first].omnifunc = "YcmTestOmnifunc"
vim.g.ycm_semantic_triggers = { ycmtest = { [[re!obj\.$]] } }
vim.api.nvim_buf_set_lines(first, 0, -1, true, { "obj." })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
equal(true, client:_omnifunc_completion(first, false), "regex semantic trigger invokes omnifunc")

-- Exercise the runtime Lua callback that used to fail through vim.fn[name].
client.omni_cache = nil
client.last_completion_response = nil
vim.bo[first].filetype = "lua"
vim.bo[first].omnifunc = "v:lua.vim.lua_omnifunc"
vim.api.nvim_buf_set_lines(first, 0, -1, true, { "vim." })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
equal(true, client:_omnifunc_completion(first, false), "Neovim's Lua omnifunc is callable")
assert(#client.last_completion_response.completions > 0, "Lua runtime completion returns candidates")
equal(5, client.last_completion_response.completion_start_column, "Lua runtime completion starts after the dot")
equal({ 1, 4 }, vim.api.nvim_win_get_cursor(0), "Lua runtime completion restores the cursor")

-- Quoting the base must preserve user text rather than interpreting it as Vimscript.
local lua_base = [[a'b\c]]
local lua_calls
local lua_omnifunc = function(findstart, base)
	lua_calls[#lua_calls + 1] = { findstart, base, vim.api.nvim_win_get_cursor(0) }
	if findstart == 1 then
		return 4
	end
	return { words = { base } }
end
_G.YcmTestOmnifunc = lua_omnifunc
package.loaded.ycm_test_omni = { complete = lua_omnifunc }
local lua_omnifuncs = { "v:lua.YcmTestOmnifunc", "v:lua.require'ycm_test_omni'.complete" }
local supports_lua_callback = pcall(function()
	vim.bo[first].omnifunc = lua_omnifunc
end)
if supports_lua_callback then
	lua_omnifuncs[#lua_omnifuncs + 1] = lua_omnifunc
end
for _, omnifunc in ipairs(lua_omnifuncs) do
	lua_calls = {}
	client.omni_cache = nil
	vim.bo[first].omnifunc = omnifunc
	vim.api.nvim_buf_set_lines(first, 0, -1, true, { "obj." .. lua_base })
	vim.api.nvim_win_set_cursor(0, { 1, 4 + #lua_base })
	equal(true, client:_omnifunc_completion(first, true), "Lua callback supports forced completion")
	equal(
		{ { 1, "", { 1, 4 + #lua_base } }, { 0, lua_base, { 1, 4 } } },
		lua_calls,
		"Lua callback receives both completion phases"
	)
	equal(
		lua_base,
		client.last_completion_response.completions[1].word,
		"Lua callback preserves quotes and backslashes"
	)
	equal({ 1, 4 + #lua_base }, vim.api.nvim_win_get_cursor(0), "Lua callback restores the cursor")
end
_G.YcmTestOmnifunc = nil
package.loaded.ycm_test_omni = nil
vim.o.virtualedit = ""

local saved_completeopt = vim.o.completeopt
vim.o.completeopt = "menu"
vim.bo[first].completeopt = ""
equal("", vim.bo[first].completeopt, "completeopt uses an unset local value")
vim.bo[first].filetype = "ycmtest"
vim.bo[first].omnifunc = ""
vim.api.nvim_buf_set_lines(first, 0, -1, true, { "alp" })
vim.api.nvim_win_set_cursor(0, { 1, 3 })
client.server.ready = true
client.available_completers.ycmtest = true
local saved_request = client.request
client.request = function(_, endpoint, _, _, callback)
	equal("completions", endpoint, "completion request uses the ycmd handler")
	callback(nil, {
		completions = { { insertion_text = "alpha" } },
		completion_start_column = 1,
	})
	return { cancel = function() end }
end
local completion_call
_G.YcmTestComplete = function()
	local ok, err = pcall(client.complete, client, false)
	completion_call = { ok = ok, err = err }
	return ""
end
local completion_keys = "i"
	.. vim.api.nvim_replace_termcodes("<C-R>=v:lua.YcmTestComplete()<CR><Esc>", true, false, true)
vim.api.nvim_feedkeys(completion_keys, "x", false)
equal(true, completion_call.ok, "completion works when completeopt has no local override")
equal("menu", vim.o.completeopt, "completion restores completeopt")
equal("", vim.bo[first].completeopt, "completion restores the unset local completeopt")
_G.YcmTestComplete = nil
client.request = saved_request
vim.o.completeopt = saved_completeopt

local visit = request.add_ultisnips_data({})
equal("for", visit.ultisnips_snippets[1].trigger, "UltiSnips candidates are sorted and serialized")
equal("entry point", visit.ultisnips_snippets[2].description, "UltiSnips descriptions are preserved")

local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(target, "/tmp/ycm-lua-target.cpp")
vim.bo[target].filetype = "cpp"
local command_data = client:_command_data({ "--bufnr=" .. target, "GetType" })
equal("/tmp/ycm-lua-target.cpp", command_data.filepath, "--bufnr commands target the requested buffer")
equal({ "GetType" }, command_data.command_arguments, "--bufnr is not sent to ycmd as a command argument")

print("Neovim Lua client unit tests passed")
