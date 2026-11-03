local h = require('helpers')
local diffsplit = require('nvim-git-flow.diffsplit')

local function fixture_lines()
    return vim.fn.readfile(h.fixtures .. '/sample.py')
end

-- Fresh state: one tab, one window, the repo's sample.py open with an unsaved edit on line 1.
local function setup()
    -- a brand-new tab, so windows left over from an earlier test (diff/fold options) are gone
    vim.cmd('tabnew')
    vim.cmd('silent! tabonly!')
    vim.wait(50)
    vim.wo.diff = false
    vim.wo.foldenable = true
    vim.g.git_diff_base = nil
    local dir = h.repo({ 'sample.py' })
    local buf = h.open(dir .. '/sample.py')
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'import sys' })
    return dir, buf
end

local function keys(k)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'xt', false)
    vim.wait(50)
end

local function tab_wins()
    return vim.api.nvim_tabpage_list_wins(0)
end

local function left_win()
    return tab_wins()[1]
end

local function assert_diff_tab(buf, name)
    h.eq(#vim.api.nvim_list_tabpages(), 2, 'tabs')
    local wins = tab_wins()
    h.eq(#wins, 2, 'diff tab windows')
    local left = vim.api.nvim_win_get_buf(wins[1])
    h.eq(vim.api.nvim_win_get_buf(wins[2]), buf, 'right is the real buffer')
    h.eq(vim.api.nvim_get_current_win(), wins[2], 'cursor on the real buffer')
    h.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(left), ':t'), name, 'left name')
    for _, w in ipairs(wins) do
        h.eq(vim.wo[w].diff, true, 'diff on')
        h.eq(vim.wo[w].foldenable, false, 'folds off')
    end
    local bo = vim.bo[left]
    h.eq({ bo.buftype, bo.bufhidden, bo.swapfile, bo.modifiable, bo.buflisted, bo.filetype },
        { 'nofile', 'wipe', false, false, false, 'python' }, 'scratch options')
    h.eq(diffsplit.is_diff_tab(), true, 'is_diff_tab')
    return left
end

-- Back on the original tab with its 2-window layout, the edit kept, diff off everywhere.
local function assert_restored(buf, layout)
    h.eq(#vim.api.nvim_list_tabpages(), 1, 'tabs after close')
    h.eq(vim.fn.winlayout(), layout, 'layout restored')
    h.eq(vim.api.nvim_buf_is_loaded(buf), true, 'source still loaded')
    h.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { 'import sys' }, 'unsaved edit kept')
    h.eq(vim.bo[buf].modified, true, 'still modified')
    for _, w in ipairs(tab_wins()) do
        h.eq(vim.wo[w].diff, false, 'diff off')
    end
    h.eq(diffsplit.is_diff_tab(), false, 'not a diff tab')
    -- q is a plain macro key again on the source buffer
    local m = vim.fn.maparg('q', 'n', false, true)
    if not vim.tbl_isempty(m) then
        h.eq(m.expr, 1, 'q map is the expr one')
        h.eq(m.callback(), 'q', 'q expr outside a diff tab')
    end
end

-- Split layout to restore: real buffer on the right of a vsplit, cursor there.
local function vsplit_layout()
    vim.cmd('vsplit')
    vim.cmd('wincmd l')
    return vim.fn.winlayout()
end

local T = {}

function T.test_tracked_file_against_head()
    local _, buf = setup()
    vim.cmd('vsplit')
    local orig_wins = tab_wins()
    h.eq(diffsplit.open(), true, 'opened')
    local left = assert_diff_tab(buf, '[HEAD] sample.py')
    h.eq(vim.api.nvim_buf_get_lines(left, 0, -1, false), fixture_lines(), 'left = committed lines')
    for _, w in ipairs(orig_wins) do
        h.eq(vim.wo[w].diff, false, 'original tab not in diff')
        h.eq(vim.wo[w].foldenable, true, 'original tab folds untouched')
    end
    diffsplit.close()
    vim.wait(50)
end

function T.test_explicit_ref()
    local dir, buf = setup()
    vim.cmd('silent write')
    h.sh(dir, { 'commit', '-q', '-am', 'second' })
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'import json' })
    h.eq(diffsplit.open('HEAD~1'), true, 'opened')
    local left = assert_diff_tab(buf, '[HEAD~1] sample.py')
    h.eq(vim.api.nvim_buf_get_lines(left, 0, -1, false), fixture_lines(), 'left = first commit')
    diffsplit.close()
    vim.wait(50)
end

function T.test_base_commit_id_label()
    local dir, buf = setup()
    local sha = vim.trim(h.sh(dir, { 'rev-parse', 'HEAD' }))
    vim.g.git_diff_base = sha
    h.eq(diffsplit.open(), true, 'opened')
    assert_diff_tab(buf, '[' .. sha:sub(1, 8) .. '] sample.py')
    diffsplit.close()
    vim.wait(50)
    vim.g.git_diff_base = nil
end

function T.test_untracked_file_against_saved()
    local dir = setup()
    local path = dir .. '/new.py'
    vim.fn.writefile(fixture_lines(), path)
    local buf = h.open(path)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'import sys' })
    h.eq(diffsplit.open(), true, 'opened')
    local left = assert_diff_tab(buf, '[saved] new.py')
    h.eq(vim.api.nvim_buf_get_lines(left, 0, -1, false), fixture_lines(), 'left = saved file')
    diffsplit.close()
    vim.wait(50)
end

function T.test_bad_ref_errors_without_tab()
    setup()
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(msg) table.insert(msgs, msg) end
    local ok = diffsplit.open('no-such-ref')
    vim.notify = notify
    h.eq(ok, false, 'not opened')
    h.eq(#vim.api.nvim_list_tabpages(), 1, 'no new tab')
    h.eq(#msgs, 1, 'one error')
    assert(msgs[1]:match('^DiffSplit: '), msgs[1])
end

function T.test_non_file_buffer_refused()
    setup()
    vim.cmd('enew')
    vim.bo.buftype = 'nofile'
    local notify = vim.notify
    local msg
    vim.notify = function(m) msg = m end
    local ok = diffsplit.open()
    vim.notify = notify
    h.eq(ok, false, 'not opened')
    h.eq(msg, 'DiffSplit: not a file buffer', 'message')
    h.eq(#vim.api.nvim_list_tabpages(), 1, 'no new tab')
end

function T.test_q_on_source_closes()
    local _, buf = setup()
    local layout = vsplit_layout()
    diffsplit.open()
    keys('q')
    assert_restored(buf, layout)
end

function T.test_q_on_left_closes()
    local _, buf = setup()
    local layout = vsplit_layout()
    diffsplit.open()
    vim.api.nvim_set_current_win(left_win())
    keys('q')
    assert_restored(buf, layout)
end

function T.test_colon_q_on_left_closes()
    local _, buf = setup()
    local layout = vsplit_layout()
    diffsplit.open()
    vim.api.nvim_set_current_win(left_win())
    vim.cmd('quit')
    vim.wait(50)
    assert_restored(buf, layout)
end

function T.test_close_api()
    local _, buf = setup()
    local layout = vsplit_layout()
    h.eq(diffsplit.close(), false, 'nothing to close')
    diffsplit.open()
    h.eq(diffsplit.close(), true, 'closed')
    vim.wait(50)
    assert_restored(buf, layout)
    h.eq(diffsplit.close(), false, 'nothing left')
end

function T.test_q_records_macro_outside_diff_tab()
    setup()
    diffsplit.open()
    diffsplit.close()
    vim.wait(50)
    vim.fn.setreg('a', '')
    keys('qaAx<Esc>q')
    h.eq(vim.fn.getreg('a'), vim.api.nvim_replace_termcodes('Ax<Esc>', true, false, true), 'macro recorded')
end

function T.test_two_diff_tabs()
    local _, buf = setup()
    local first_tab = vim.api.nvim_get_current_tabpage()
    diffsplit.open()
    local tab_a = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(first_tab)
    diffsplit.open()
    h.eq(#vim.api.nvim_list_tabpages(), 3, 'three tabs')
    keys('q')
    h.eq(#vim.api.nvim_list_tabpages(), 2, 'one diff tab left')
    h.eq(vim.api.nvim_get_current_tabpage(), first_tab, 'back on the first tab')
    vim.api.nvim_set_current_tabpage(tab_a)
    h.eq(diffsplit.is_diff_tab(), true, 'other diff still live')
    keys('q')
    h.eq(#vim.api.nvim_list_tabpages(), 1, 'all closed')
    h.eq(vim.api.nvim_buf_is_loaded(buf), true, 'source loaded')
end

function T.test_last_tab_only_diffoff()
    local _, buf = setup()
    diffsplit.open()
    local diff_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabonly')
    h.eq(vim.api.nvim_get_current_tabpage(), diff_tab, 'diff tab kept')
    keys('q')
    h.eq(#vim.api.nvim_list_tabpages(), 1, 'one tab')
    h.eq(#tab_wins(), 1, 'left window gone')
    h.eq(vim.api.nvim_win_get_buf(0), buf, 'source shown')
    h.eq(vim.wo.diff, false, 'diff off')
end

-- Both widths, left then right, of the current diff tab.
local function widths()
    return { vim.api.nvim_win_get_width(tab_wins()[1]), vim.api.nvim_win_get_width(tab_wins()[2]) }
end

local function resize(cols)
    vim.o.columns = cols
    vim.api.nvim_exec_autocmds('VimResized', {})
end

function T.test_terminal_shrink_keeps_both_sides()
    setup()
    resize(120)
    diffsplit.open()
    resize(60)
    local w = widths()
    assert(math.abs(w[1] - w[2]) <= 1, 'even split after shrink: ' .. vim.inspect(w))
    resize(120)
    w = widths()
    assert(math.abs(w[1] - w[2]) <= 1, 'even split after grow: ' .. vim.inspect(w))
    keys('q')
end

function T.test_background_diff_tab_evened_on_return()
    setup()
    resize(120)
    local first_tab = vim.api.nvim_get_current_tabpage()
    diffsplit.open()
    local diff_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(first_tab)
    resize(60)
    vim.cmd('tabnext ' .. vim.api.nvim_tabpage_get_number(diff_tab))
    local w = widths()
    assert(math.abs(w[1] - w[2]) <= 1, 'even split on return: ' .. vim.inspect(w))
    h.eq(vim.t.diffsplit_resized, nil, 'flag cleared')
    keys('q')
end

function T.test_manual_split_width_kept_without_resize()
    setup()
    resize(120)
    diffsplit.open()
    vim.api.nvim_win_set_width(tab_wins()[1], 30)
    vim.cmd('tabprevious')
    vim.cmd('tabnext')
    h.eq(widths()[1], 30, 'your own split width stays')
    keys('q')
end

function T.test_cursor_carried_back_on_close()
    local _, buf = setup()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local from_win = vim.api.nvim_get_current_win()
    diffsplit.open()
    vim.api.nvim_win_set_cursor(0, { 18, 4 })
    keys('q')
    h.eq(vim.api.nvim_get_current_win(), from_win, 'back in the window you came from')
    h.eq(vim.api.nvim_win_get_buf(0), buf, 'same buffer')
    h.eq(vim.api.nvim_win_get_cursor(0), { 18, 4 }, 'cursor where it was in the diff')
end

function T.test_cursor_carried_back_from_left_side()
    local _, buf = setup()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    diffsplit.open()
    vim.api.nvim_win_set_cursor(0, { 20, 0 })
    vim.cmd('wincmd h')
    keys('q')
    h.eq(vim.api.nvim_win_get_buf(0), buf, 'same buffer')
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 20, 'cursor line from the diff')
end

return T
