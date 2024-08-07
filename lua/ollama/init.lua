local M = {}
local globals = {}

function M.setup(opts)
	opts = opts or {}
end

local function write_to_buffer(lines)
	if not globals.result_buffer or not vim.api.nvim_buf_is_valid(globals.result_buffer) then
		return
	end

	local all_lines = vim.api.nvim_buf_get_lines(globals.result_buffer, 0, -1, false)

	local last_row = #all_lines
	local last_row_content = all_lines[last_row]
	local last_col = string.len(last_row_content)

	local text = table.concat(lines or {}, "\n")

	vim.api.nvim_set_option_value("modifiable", true, { buf = globals.result_buffer })
	vim.api.nvim_buf_set_text(
		globals.result_buffer,
		last_row - 1,
		last_col,
		last_row - 1,
		last_col,
		vim.split(text, "\n")
	)
	-- Move the cursor to the end of the new lines
	local new_last_row = last_row + #lines - 1
	vim.api.nvim_win_set_cursor(globals.float_win, { new_last_row, 0 })

	vim.api.nvim_set_option_value("modifiable", false, { buf = globals.result_buffer })
end

M.run_command = function(cmd, opts)
	local partial_data = ""
	if opts.debug then
		print(cmd)
	end

	Job_id = vim.fn.jobstart(cmd, {
		-- stderr_buffered = opts.debug,
		on_stdout = function(_, data, _)
			if opts.debug then
				vim.print("Response data: ", data)
			end
			for _, line in ipairs(data) do
				partial_data = partial_data .. line
				if line:sub(-1) == "}" then
					partial_data = partial_data .. "\n"
				end
			end

			local lines = vim.split(partial_data, "\n", { trimempty = true })

			partial_data = table.remove(lines) or ""

			for _, line in ipairs(lines) do
				Process_response(line, Job_id, opts.json_response)
			end

			if partial_data:sub(-1) == "}" then
				Process_response(partial_data, Job_id, opts.json_response)
				partial_data = ""
			end
		end,
		on_stderr = function(_, data, _)
			if opts.debug then
				if data == nil or #data == 0 then
					return
				end
				globals.result_string = globals.result_string .. table.concat(data, "\n")
				local lines = vim.split(globals.result_string, "\n")
				write_to_buffer(lines)
			end
		end,
	})
end
function Process_response(str, job_id, json_response)
	if string.len(str) == 0 then
		return
	end
	local text

	if json_response then
		-- llamacpp response string -- 'data: {"content": "hello", .... }' -- remove 'data: ' prefix, before json_decode
		if string.sub(str, 1, 6) == "data: " then
			str = string.gsub(str, "data: ", "", 1)
		end
		local success, result = pcall(function()
			return vim.fn.json_decode(str)
		end)

		if success then
			if result.message and result.message.content then -- ollama chat endpoint
				local content = result.message.content
				text = content

				globals.context = globals.context or {}
				globals.context_buffer = globals.context_buffer or ""
				globals.context_buffer = globals.context_buffer .. content

				-- When the message sequence is complete, add it to the context
				if result.done then
					table.insert(globals.context, {
						role = "assistant",
						content = globals.context_buffer,
					})
					-- Clear the buffer as we're done with this sequence of messages
					globals.context_buffer = ""
				end
			elseif result.choices then -- groq chat endpoint
				local choice = result.choices[1]
				local content = choice.delta.content
				text = content

				if content ~= nil then
					globals.context = globals.context or {}
					globals.context_buffer = globals.context_buffer or ""
					globals.context_buffer = globals.context_buffer .. content
				end

				-- When the message sequence is complete, add it to the context
				if choice.finish_reason == "stop" then
					table.insert(globals.context, {
						role = "assistant",
						content = globals.context_buffer,
					})
					-- Clear the buffer as we're done with this sequence of messages
					globals.context_buffer = ""
				end
			elseif result.content then -- llamacpp version
				text = result.content
				if result.content then
					globals.context = result.content
				end
			elseif result.response then -- ollama generate endpoint
				text = result.response
				if result.context then
					globals.context = result.context
				end
			end
		else
			write_to_buffer({ "", "====== ERROR ====", str, "-------------", "" })
			vim.fn.jobstop(job_id)
		end
	else
		text = str
	end

	if text == nil then
		return
	end

	globals.result_string = globals.result_string .. text
	local lines = vim.split(text, "\n")
	write_to_buffer(lines)
end

vim.api.nvim_create_user_command("Ollama", function(arg)
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row = cursor[1]
	local prefix = vim.api.nvim_buf_get_lines(buf, 0, row, false)
	local suffix = vim.api.nvim_buf_get_lines(buf, row, -1, false)
	vim.cmd("enew")
	globals.result_buffer = vim.fn.bufnr("%")
	-- M.run_command(cmd, opts)
	local sp = table.concat(prefix, "\\n")
	local ss = table.concat(suffix, "\\n")
	local body = "<|fim_begin|>" .. sp .. "<|fim_hole|>" .. ss .. "<|fim_end|>"
	vim.api.nvim_buf_set_text(globals.result_buffer, 0, 0, -1, -1, { body })
	-- vim.api.nvim_buf_set_lines(0, 0, -1, false, { body })
	-- vim.api.nvim_buf_set_lines(0, -1, -1, false, { ss })
end, {
	range = true,
	nargs = "?",
	complete = function(ArgLead)
		local promptKeys = {}
		for key, _ in pairs(M.prompts) do
			if key:lower():match("^" .. ArgLead:lower()) then
				table.insert(promptKeys, key)
			end
		end
		table.sort(promptKeys)
		return promptKeys
	end,
})

return M
