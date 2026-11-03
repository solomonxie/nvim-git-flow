local h = require('helpers')
local signs = require('nvim-git-flow.signs')

signs.setup()

local T = {}

-- Open sample.py from a fresh repo, with its base loaded.
local function open_sample()
    local dir = h.repo({ 'sample.py' })
    local buf = h.open(dir .. '/sample.py')
    vim.g.git_diff_base = nil
    signs.refresh(buf, { sync = true })
    return buf, dir
end

local function set(buf, first, last, lines)
    vim.api.nvim_buf_set_lines(buf, first - 1, last, false, lines)
end

local function kinds(buf)
    local out = {}
    for _, hk in ipairs(signs.get_hunks(buf)) do
        out[#out + 1] = { hk.type, hk.start, hk.count, hk.old_start, hk.old_count }
    end
    return out
end

local function sign_at(buf, lnum)
    local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['nvim-git-flow.signs'],
        { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
    return marks[1] and marks[1][4].sign_hl_group
end

function T.test_unchanged_has_no_hunks()
    local buf = open_sample()
    h.eq(signs.get_hunks(buf), {}, 'hunks')
end

function T.test_add()
    local buf = open_sample()
    set(buf, 7, 6, { 'NEW = 1' })  -- insert after line 6
    h.eq(signs.get_hunks(buf), { {
        type = 'add', start = 7, count = 1, old_start = 6, old_count = 0,
        old_lines = {}, new_lines = { 'NEW = 1' },
    } }, 'hunks')
    h.eq(sign_at(buf, 7), 'GitFlowAdd', 'sign')
end

function T.test_change()
    local buf = open_sample()
    set(buf, 5, 5, { '    total = a * b' })
    h.eq(signs.get_hunks(buf), { {
        type = 'change', start = 5, count = 1, old_start = 5, old_count = 1,
        old_lines = { '    total = a + b' }, new_lines = { '    total = a * b' },
    } }, 'hunks')
    h.eq(sign_at(buf, 5), 'GitFlowChange', 'sign')
end

function T.test_delete()
    local buf = open_sample()
    set(buf, 10, 11, {})  -- drop `out = []` and the for line
    h.eq(kinds(buf), { { 'delete', 9, 0, 10, 2 } }, 'hunks')
    h.eq(signs.get_hunks(buf)[1].old_lines, { '    out = []', '    for item in items:' }, 'old lines')
    h.eq(sign_at(buf, 9), 'GitFlowDelete', 'sign')
end

function T.test_delete_at_top()
    local buf = open_sample()
    set(buf, 1, 1, {})
    h.eq(kinds(buf), { { 'delete', 0, 0, 1, 1 } }, 'hunks')
    h.eq(sign_at(buf, 1), 'GitFlowDelete', 'sign')
    local mark = vim.api.nvim_buf_get_extmarks(buf, -1, 0, 0, { details = true })[1]
    h.eq(vim.trim(mark[4].sign_text), '▔', 'topdelete text')
end

function T.test_changedelete()
    local buf = open_sample()
    set(buf, 10, 12, { '    return [i * 2 for i in items]' })  -- 3 old lines -> 1
    set(buf, 11, 11, {})  -- and the old return line goes too
    h.eq(kinds(buf), { { 'change', 10, 1, 10, 4 } }, 'hunks')
    h.eq(sign_at(buf, 10), 'GitFlowChangeDelete', 'sign')
end

function T.test_untracked_is_all_add()
    local dir = h.repo({ 'sample.py' })
    vim.fn.writefile(vim.fn.readfile(h.fixtures .. '/sample.py'), dir .. '/new.py')
    local buf = h.open(dir .. '/new.py')
    signs.refresh(buf, { sync = true })
    h.eq(kinds(buf), { { 'add', 1, 27, 0, 0 } }, 'hunks')
end

function T.test_outside_git_has_no_signs()
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ 'x' }, dir .. '/plain.txt')
    local buf = h.open(dir .. '/plain.txt')
    signs.refresh(buf, { sync = true })
    set(buf, 1, 1, { 'y' })
    h.eq(signs.get_hunks(buf), {}, 'hunks')
end

function T.test_async_open_draws_signs()
    local dir = h.repo({ 'sample.py' })
    local lines = vim.fn.readfile(dir .. '/sample.py')
    lines[5] = '    total = 0'
    vim.fn.writefile(lines, dir .. '/sample.py')
    local buf = h.open(dir .. '/sample.py')  -- BufReadPost starts the git show in the background
    assert(vim.wait(5000, function()
        return #signs.get_hunks(buf) == 1
    end), 'signs never arrived')
    h.eq(kinds(buf), { { 'change', 5, 1, 5, 1 } }, 'hunks')
end

function T.test_base_change()
    local buf, dir = open_sample()
    local first = vim.trim(h.sh(dir, { 'rev-parse', 'HEAD' }))
    set(buf, 5, 5, { '    total = a - b' })
    vim.cmd('silent write')
    h.sh(dir, { 'commit', '-q', '-am', 'second' })
    signs.refresh(buf, { sync = true })
    h.eq(signs.get_hunks(buf), {}, 'clean vs HEAD')

    vim.g.git_diff_base = first
    vim.api.nvim_exec_autocmds('User', { pattern = 'GitDiffBaseChanged' })
    assert(vim.wait(5000, function()
        return #signs.get_hunks(buf) == 1
    end), 'base change never showed')
    h.eq(kinds(buf), { { 'change', 5, 1, 5, 1 } }, 'hunks vs first commit')
    vim.g.git_diff_base = nil
end

function T.test_undo_hunk()
    local buf = open_sample()
    local orig = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    set(buf, 5, 6, { '    return a * b' })
    set(buf, 20, 19, { 'EXTRA = 2' })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    signs.undo_hunk()
    h.eq(kinds(buf), { { 'add', 21, 1, 20, 0 } }, 'only the other hunk is left')
    vim.api.nvim_win_set_cursor(0, { 21, 0 })
    signs.undo_hunk()
    h.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), orig, 'buffer back to base')
end

function T.test_undo_delete_at_top()
    local buf = open_sample()
    local orig = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    set(buf, 1, 2, {})
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    signs.undo_hunk()
    h.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), orig, 'buffer back to base')
end

function T.test_stage_hunk()
    local buf, dir = open_sample()
    set(buf, 5, 5, { '    total = a * b' })
    set(buf, 24, 24, { '        self.value = value or 0' })
    vim.api.nvim_win_set_cursor(0, { 24, 0 })
    signs.stage_hunk()
    local cached = h.sh(dir, { 'diff', '--cached', '-U0', '--no-color' })
    local body = vim.tbl_filter(function(l)
        return l:match('^[-+@]') and not l:match('^%-%-%-') and not l:match('^%+%+%+')
    end, vim.split(cached, '\n'))
    h.eq(body, {
        '@@ -24 +24 @@ class Holder:',
        '-        self.value = value',
        '+        self.value = value or 0',
    }, 'staged diff')
    -- the buffer was never written: the work tree file is untouched
    h.eq(vim.fn.readfile(dir .. '/sample.py')[24], '        self.value = value', 'work tree')
end

function T.test_stage_hunk_below_unstaged_add()
    local buf, dir = open_sample()
    set(buf, 2, 1, { 'import sys', 'import re' })  -- unstaged, shifts the lines below by 2
    set(buf, 15, 15, {})  -- `return out`: line 13 in the index, 15 in the buffer
    local hunks = signs.get_hunks(buf)
    h.eq(#hunks, 2, 'two hunks')
    vim.api.nvim_win_set_cursor(0, { hunks[2].start, 0 })
    signs.stage_hunk()
    local cached = h.sh(dir, { 'diff', '--cached', '-U0', '--no-color' })
    assert(cached:match('\n%-    return out\n'), 'staged deletion: ' .. cached)
    assert(not cached:match('import sys'), 'the add stayed unstaged: ' .. cached)
end

function T.test_next_prev_wrap()
    local buf = open_sample()
    set(buf, 5, 5, { '    total = 0' })
    set(buf, 17, 17, { '    if path:' })
    set(buf, 26, 27, {})
    h.eq(vim.tbl_map(function(x) return x.start end, signs.get_hunks(buf)), { 5, 17, 25 }, 'starts')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    signs.next_hunk()
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 5, 'next')
    signs.next_hunk()
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 17, 'next')
    signs.next_hunk()
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 25, 'next delete')
    signs.next_hunk()
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 5, 'wrapped to first')
    signs.prev_hunk()
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 25, 'wrapped to last')
    signs.prev_hunk()
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 17, 'prev')
    vim.cmd('normal! \15')  -- <C-o>
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 25, 'jumplist')
end

function T.test_hunk_summary()
    local buf = open_sample()
    set(buf, 5, 5, { '    total = 0' })
    set(buf, 7, 6, { 'A = 1', 'B = 2' })
    set(buf, 12, 13, {})
    h.eq(signs.hunk_summary(buf), { added = 2, changed = 1, removed = 2 }, 'summary')
end

function T.test_preview_and_loclist()
    local buf = open_sample()
    set(buf, 5, 5, { '    total = 0' })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local wins = #vim.api.nvim_list_wins()
    signs.preview_hunk()
    h.eq(#vim.api.nvim_list_wins(), wins + 1, 'float opened')
    local float
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then
            float = w
        end
    end
    h.eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false),
        { '@@ -5,1 +5,1 @@', '-    total = a + b', '+    total = 0' }, 'preview text')
    signs.preview_hunk()
    h.eq(vim.api.nvim_get_current_win(), float, 'second press focuses')
    vim.cmd('normal q')
    vim.wait(50)
    h.eq(#vim.api.nvim_list_wins(), wins, 'q closed it')

    signs.to_loclist()
    local ll = vim.fn.getloclist(vim.fn.win_getid(vim.fn.winnr('#')))
    vim.cmd('lclose')
    h.eq(#ll, 1, 'loclist items')
    h.eq(ll[1].lnum, 5, 'loclist line')
end

function T.test_toggle_fold()
    local buf = open_sample()
    set(buf, 5, 5, { '    total = 0' })
    signs.toggle_fold()
    h.eq(vim.fn.foldclosed(1), -1, 'context stays open')
    h.eq(vim.fn.foldclosed(15), 9, 'far lines fold')
    signs.toggle_fold()
    h.eq(vim.wo.foldmethod, 'manual', 'restored')
    h.eq(vim.fn.foldclosed(15), -1, 'unfolded')
end

return T
