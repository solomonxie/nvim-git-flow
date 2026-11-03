local h = require('helpers')
local blame = require('nvim-git-flow.blame')

local T = {}

local ns = vim.api.nvim_create_namespace('nvim_git_flow_blame')

local function read(name)
    return table.concat(vim.fn.readfile(h.fixtures .. '/' .. name), '\n') .. '\n'
end

-- virtual text on the cursor line, waiting for the background blame job
local function cursor_text(want)
    local text
    vim.wait(5000, function()
        local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
        text = marks[1] and marks[1][4].virt_text[1][1] or nil
        return text ~= nil and (want == nil or text:find(want, 1, true) ~= nil)
    end, 20)
    return text
end

local function off()
    if blame.enabled() then
        blame.toggle()
    end
end

-- fixture: sample.py committed by Test on 2026-10-01 12:00Z, line 5 changed by Alice Doe on
-- 2026-11-01 10:00Z, line 10 edited in the buffer only
local NOW = 1793527200 + 3600

function T.test_parse_porcelain_one_entry_per_line()
    local lines = blame.parse_porcelain(read('sample.py.blame-porcelain'), NOW)
    h.eq(#lines, 27)
end

function T.test_parse_porcelain_old_commit_days_ago()
    local lines = blame.parse_porcelain(read('sample.py.blame-porcelain'), NOW)
    h.eq(lines[1], 'Test, 30 days ago - fixtures')
    h.eq(lines[27], 'Test, 30 days ago - fixtures')
end

function T.test_parse_porcelain_today()
    local lines = blame.parse_porcelain(read('sample.py.blame-porcelain'), NOW)
    h.eq(lines[5], 'Alice Doe, today - Add zero to total')
end

function T.test_parse_porcelain_uncommitted()
    local lines = blame.parse_porcelain(read('sample.py.blame-porcelain'), NOW)
    h.eq(lines[10], 'Not committed yet')
end

function T.test_parse_porcelain_empty()
    h.eq(blame.parse_porcelain('', NOW), {})
end

function T.test_toggle_shows_cursor_line_blame()
    off()
    local dir = h.repo({ 'sample.py' })
    h.open(dir .. '/sample.py')
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    h.eq(blame.toggle(), true)
    h.eq(blame.enabled(), true)
    h.eq(cursor_text(), '  Test, today - fixtures')
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    h.eq(#marks, 1)
    h.eq(marks[1][2], 3, 'extmark row')
    off()
end

function T.test_toggle_off_clears_text()
    off()
    local dir = h.repo({ 'sample.py' })
    h.open(dir .. '/sample.py')
    blame.toggle()
    cursor_text()
    h.eq(blame.toggle(), false)
    h.eq(blame.enabled(), false)
    h.eq(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}), {})
end

function T.test_cursor_moved_follows_cursor()
    off()
    local dir = h.repo({ 'sample.py' })
    h.open(dir .. '/sample.py')
    blame.toggle()
    cursor_text()
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    h.eq(#marks, 1)
    h.eq(marks[1][2], 8, 'extmark row')
    off()
end

function T.test_edit_reblames_as_not_committed()
    off()
    local dir = h.repo({ 'sample.py' })
    h.open(dir .. '/sample.py')
    blame.toggle()
    cursor_text()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_buf_set_lines(0, 4, 5, false, { '    total = a - b' })
    vim.api.nvim_exec_autocmds('TextChanged', {})
    h.eq(cursor_text('Not committed'), '  Not committed yet')
    off()
end

function T.test_untracked_file_not_committed()
    off()
    local dir = h.repo({ 'sample.py' })
    vim.fn.writefile(vim.fn.readfile(h.fixtures .. '/sample.py'), dir .. '/new.py')
    h.open(dir .. '/new.py')
    blame.toggle()
    h.eq(cursor_text(), '  Not committed yet')
    off()
end

function T.test_symlink_blames_in_real_repo()
    off()
    local dir = h.repo({ 'sample.py' })
    local link_dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(link_dir, 'p')
    vim.uv.fs_symlink(dir .. '/sample.py', link_dir .. '/linked.py')
    h.open(link_dir .. '/linked.py')
    blame.toggle()
    h.eq(cursor_text(), '  Test, today - fixtures')
    off()
end

return T
