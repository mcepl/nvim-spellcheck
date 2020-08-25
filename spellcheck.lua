-- Copyright (c) 2017-2019 Florian Fischer. All rights reserved.
-- Use of this source code is governed by a MIT license found in the LICENSE file.

local spellcheck = {}
spellcheck.lang = os.getenv("LANG"):sub(0,5) or "en_US"
local supress_output = ">/dev/null 2>/dev/null"
if os.execute("type enchant "..supress_output) then
	spellcheck.cmd = "enchant -d %s -a"
	spellcheck.list_cmd = "enchant -l -d %s -a"
elseif os.execute("type enchant-2 "..supress_output) then
	spellcheck.cmd = "enchant-2 -d %s -a"
	spellcheck.list_cmd = "enchant-2 -l -d %s -a"
elseif os.execute("type aspell "..supress_output) then
	spellcheck.cmd = "aspell -l %s -a"
	spellcheck.list_cmd = "aspell list -l %s -a"
elseif os.execute("type hunspell "..supress_output) then
	spellcheck.cmd = "hunspell -d %s"
	spellcheck.list_cmd = "hunspell -l -d %s"
else
   return nil
end

spellcheck.typo_style = "fore:red"
spellcheck.check_full_viewport = {}

spellcheck.check_tokens = {
	[vis.lexers.STRING] = true,
	[vis.lexers.COMMENT] = true
}

local ignored = {}

local last_viewport, last_typos = nil, ""

vis.events.subscribe(vis.events.WIN_HIGHLIGHT, function(win)
	if not spellcheck.check_full_viewport[win] or not win:style_define(42, spellcheck.typo_style) then
		return false
	end
	local viewport = win.viewport
	local viewport_text = win.file:content(viewport)

	local typos = ""

	if last_viewport == viewport_text then
		typos = last_typos
	else
		local cmd = spellcheck.list_cmd:format(spellcheck.lang)
		local ret, so, se = vis:pipe(win.file, viewport, cmd)
		if ret ~= 0 then
			vis:message("calling " .. cmd .. " failed ("..se..")")
			return false
		end
		typos = so or ""
	end

	local corrections_iter = typos:gmatch("(.-)\n")
	local index = 1
	for typo in corrections_iter do
		if not ignored[typo] then
			local start, finish = viewport_text:find(typo, index, true)
			win:style(42, viewport.start + start - 1, viewport.start + finish)
			index = finish
		end
	end

	last_viewport = viewport_text
	last_typos = typos
	return true
end)

local wrapped_lex_funcs = {}

local wrap_lex_func = function(old_lex_func)
	return function(lexer, data, index, redrawtime_max)
		-- vis:info("hooked lexer.lex")
		local tokens, timedout = old_lex_func(lexer, data, index, redrawtime_max)

		-- quit early if the lexer already took to long
		-- TODO: investigate further if timedout is actually set by the lexer.
		--       As I understand lpeg.match used by lexer.lex timedout will always be nil
		if timeout then
			return tokens, timedout
		end

		local log = nil
		local win = vis.win
		local cmd = spellcheck.list_cmd:format(spellcheck.lang)
		local new_tokens = {}

		-- get file position we lex
		-- duplicated code with vis-std.lua
		local viewport = win.viewport
		local horizon_max = win.horizon or 32768
		local horizon = viewport.start < horizon_max and viewport.start or horizon_max
		local view_start = viewport.start
		local lex_start = viewport.start - horizon
		local token_end = lex_start + (tokens[#tokens] or 1) - 1

		for i = 1, #tokens - 1, 2 do
			local token_start = lex_start + (tokens[i-1] or 1) - 1
			local token_end = tokens[i+1]
			local token_range = {start = token_start, finish = token_end - 1}

			-- check if token is visable
			if token_start >= view_start or token_end > view_start then
				local token_name = tokens[i]
				-- token is not listed for spellchecking just add it to the token stream
				if not spellcheck.check_tokens[token_name] then
					table.insert(new_tokens, tokens[i])
					table.insert(new_tokens, token_end)
				-- spellcheck the token
				else
					local ret, stdout, stderr = vis:pipe(win.file, token_range, cmd)
					if ret ~= 0 then
						vis:info("calling cmd: `" .. cmd .. "` failed ("..ret..")")
					-- we got misspellings
					elseif stdout then
						local typo_iter = stdout:gmatch("(.-)\n")
						local token_content = win.file:content(token_range)

						-- current position in token_content
						local index = 1
						for typo in typo_iter do
							if not ignored[typo] then
								local start, finish = token_content:find(typo, index, true)
								-- split token
								local pre_typo_end = start - 1
								-- correct part before typo
								if pre_typo_end > index then
									table.insert(new_tokens, token_name)
									table.insert(new_tokens, token_start + pre_typo_end)
								end
								-- typo
								-- TODO make style configurable
								table.insert(new_tokens, vis.lexers.ERROR)
								table.insert(new_tokens, token_start + finish + 1)
								index = finish
							end
						end
						-- rest which is not already inserted into the token stream
						table.insert(new_tokens, token_name)
						table.insert(new_tokens, token_end)
					-- found no misspellings just add it to the token stream
					else
						table.insert(new_tokens, token_name)
						table.insert(new_tokens, token_end)
					end
					-- comment with mispellings anf oter stuf
				end
			end
		end
		return new_tokens, timedout
	end
end

local enable_spellcheck = function()
	-- prevent wrapping the lex function multiple times
	if wrapped_lex_funcs[vis.win] then
		return
	end

	if vis.win.syntax and vis.lexers.load then
		local lexer = vis.lexers.load(vis.win.syntax, nil, true)
		if lexer and lexer.lex then
			local old_lex_func = lexer.lex
			wrapped_lex_funcs[vis.win] = old_lex_func
			lexer.lex = wrap_lex_func(old_lex_func)
			return
		end
	end

	-- fallback check spellcheck the full viewport
	spellcheck.check_full_viewport[vis.win] = true
end

local is_spellcheck_enabled = function()
	return spellcheck.check_full_viewport[vis.win] or wrapped_lex_funcs[vis.win]
end

vis:map(vis.modes.NORMAL, "<C-w>e", function(keys)
	enable_spellcheck()
end, "Enable spellchecking in the current window")

local disable_spellcheck = function()
	local old_lex_func = wrapped_lex_funcs[vis.win]
	if old_lex_func then
		local lexer = vis.lexers.load(vis.win.syntax, nil, true)
		lexer.lex = old_lex_func
		wrapped_lex_funcs[vis.win] = nil
	else
		spellcheck.check_full_viewport[vis.win] = nil
	end
end

vis:map(vis.modes.NORMAL, "<C-w>d", function(keys)
	disable_spellcheck()
	-- force new highlight
	vis.win:draw()
end, "Disable spellchecking in the current window")

-- toggle spellchecking on <F7>
-- <F7> is used by some word processors (LibreOffice) for spellchecking
-- Thanks to @leorosa for the hint.
vis:map(vis.modes.NORMAL, "<F7>", function(keys)
	if not is_spellcheck_enabled() then
		enable_spellcheck()
	else
		disable_spellcheck()
		vis.win:draw()
	end
	return 0
end, "Toggle spellchecking in the current window")

vis:map(vis.modes.NORMAL, "<C-w>w", function(keys)
	local win = vis.win
	local file = win.file
	local pos = win.selection.pos
	if not pos then return end
	local range = file:text_object_word(pos);
	if not range then return end
	if range.start == range.finish then return end

	local cmd = spellcheck.cmd:format(spellcheck.lang)
	local ret, so, se = vis:pipe(win.file, range, cmd)
	if ret ~= 0 then
		vis:message("calling " .. cmd .. " failed ("..se..")")
		return false
	end

	local suggestions = nil
	local answer_line = so:match(".-\n(.-)\n.*")
	local first_char = answer_line:sub(0,1)
	if first_char == "*" then
		vis:info(file:content(range).." is correctly spelled")
		return true
	elseif first_char == "#" then
		vis:info("No corrections available for "..file:content(range))
		return false
	elseif first_char == "&" then
		suggestions = answer_line:match("& %S+ %d+ %d+: (.*)")
	else
		vis:info("Unknown answer: "..answer_line)
		return false
	end

	-- select a correction
	local cmd = 'printf "' .. suggestions:gsub(", ", "\\n") .. '\\n" | vis-menu'
	local f = io.popen(cmd)
	local correction = f:read("*all")
	f:close()
	-- trim correction
	correction = correction:match("^%s*(.-)%s*$")
	if correction ~= "" then
		win.file:delete(range)
		win.file:insert(range.start, correction)
	end

	win.selection.pos = pos

	win:draw()

	return 0
end, "Correct misspelled word")

vis:map(vis.modes.NORMAL, "<C-w>i", function(keys)
	local win = vis.win
	local file = win.file
	local pos = win.selection.pos
	if not pos then return end
	local range = file:text_object_word(pos);
	if not range then return end
	if range.start == range.finish then return end

	ignored[file:content(range)] = true

	win:draw()
	return 0
end, "Ignore misspelled word")

vis:option_register("spelllang", "string", function(value, toggle)
	spellcheck.lang = value
	vis:info("Spellchecking language is now "..value)
	-- force new highlight
	last_viewport = nil
	return true
end, "The language used for spellchecking")

return spellcheck
