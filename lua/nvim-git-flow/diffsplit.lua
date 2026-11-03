-- :DiffSplit [ref] -> side-by-side line diff of this buffer (unsaved edits included) against the
-- file at a git ref, default the shared diff base (see base.lua). Untracked or non-git files
-- compare against the saved file on disk.
--
-- Opens in its own tab, so your windows stay as they are and the diff/fold settings belong to
-- that tab's windows only: right = your real buffer (edits stay), left = a read-only scratch copy.
-- q in either window (or :q on the left, or close() from your own close-buffer mapping) ends it
-- and brings you back to the tab you came from. ]c / [c jump between changes; folds are off,
-- zi brings them back. When the terminal is resized (a tmux pane dragged, say) both sides are
-- split evenly again, instead of Neovim taking all the lost width from your buffer on the right.
--
-- Tab-local state (so several diff tabs can be open at once):
--   t:diffsplit_buf   the scratch copy's buffer number (-1 / unset: not a diff tab)
--   t:diffsplit_src   the user's buffer being compared
--   t:diffsplit_from  the tab the diff was opened from
--   t:diffsplit_resized  the terminal was resized while this diff tab was in the background

local git = require('nvim-git-flow.git')
local base = require('nvim-git-flow.base')

local M = {}

local Q_DESC = 'nvim-git-flow: q ends the DiffSplit tab'

local function err(msg)
    vim.notify('DiffSplit: ' .. msg, vim.log.levels.ERROR)
end

local function tab_diff_buf(tab)
    local ok, buf = pcall(vim.api.nvim_tabpage_get_var, tab or 0, 'diffsplit_buf')
    if ok and type(buf) == 'number' and buf > 0 and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    return nil
end

-- True when the current tab holds a live diff.
function M.is_diff_tab()
    return tab_diff_buf(0) ~= nil
end

-- Does any tab other than `skip` still diff `src`?
local function src_in_use(src, skip)
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if tab ~= skip and tab_diff_buf(tab) then
            local ok, s = pcall(vim.api.nvim_tabpage_get_var, tab, 'diffsplit_src')
            if ok and s == src then
                return true
            end
        end
    end
    return false
end

-- Drop our q mapping from the user's buffer once no diff tab shows it any more.
local function unmap_src(src)
    if not vim.api.nvim_buf_is_valid(src) then
        return
    end
    local m
    vim.api.nvim_buf_call(src, function()
        m = vim.fn.maparg('q', 'n', false, true)
    end)
    if m.buffer == 1 and m.desc == Q_DESC then
        pcall(vim.keymap.del, 'n', 'q', { buffer = src })
    end
end

-- Runs once the scratch copy is wiped (q, :q, close(), :bwipeout): close the diff tab and go
-- back to the tab the diff came from; in the last tab only turn the diff off.
local function finish(src_win, src_buf, copy)
    if not vim.api.nvim_win_is_valid(src_win) then
        return  -- tab already gone
    end
    local tab = vim.api.nvim_win_get_tabpage(src_win)
    local ok, cur = pcall(vim.api.nvim_tabpage_get_var, tab, 'diffsplit_buf')
    if not ok or cur ~= copy then
        return  -- already handled, or a newer diff lives in this tab
    end
    local ok_from, from = pcall(vim.api.nvim_tabpage_get_var, tab, 'diffsplit_from')
    vim.api.nvim_tabpage_set_var(tab, 'diffsplit_buf', -1)
    if not src_in_use(src_buf, tab) then
        unmap_src(src_buf)
    end
    if #vim.api.nvim_list_tabpages() > 1 then
        local was_current = tab == vim.api.nvim_get_current_tabpage()
        vim.cmd('tabclose ' .. vim.api.nvim_tabpage_get_number(tab))
        if was_current and ok_from and vim.api.nvim_tabpage_is_valid(from) then
            vim.api.nvim_set_current_tabpage(from)
        end
    else
        vim.api.nvim_win_call(src_win, function()
            vim.cmd('diffoff')
        end)
    end
end

-- End the current tab's diff. Returns true when there was one.
function M.close()
    local copy = tab_diff_buf(0)
    if not copy then
        return false
    end
    local src_win = vim.t.diffsplit_src_win
    local src_buf = vim.t.diffsplit_src
    vim.api.nvim_buf_delete(copy, { force = true })
    -- the BufWipeout hook also schedules this; finish() runs only once per diff
    if src_win then
        finish(src_win, src_buf, copy)
    end
    return true
end

-- q on the user's buffer: inside a live diff tab end it; anywhere else record a macro as usual.
local function q_expr()
    if M.is_diff_tab() then
        return "<Cmd>lua require('nvim-git-flow.diffsplit').close()<CR>"
    end
    return 'q'
end

-- Split the current diff tab's two windows evenly.
local function equalize()
    if M.is_diff_tab() then
        vim.cmd('wincmd =')
    end
    vim.t.diffsplit_resized = nil
end

-- Neovim fits a narrower terminal by shrinking the rightmost window, which hides the real
-- buffer. Re-split the visible diff tab now, and background diff tabs once you go back to them.
local resize_hooked = false
local function hook_resize()
    if resize_hooked then
        return
    end
    resize_hooked = true
    local group = vim.api.nvim_create_augroup('NvimGitFlowDiffSplit', { clear = true })
    vim.api.nvim_create_autocmd('VimResized', {
        group = group,
        callback = function()
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                if tab_diff_buf(tab) then
                    vim.api.nvim_tabpage_set_var(tab, 'diffsplit_resized', true)
                end
            end
            equalize()
        end,
    })
    vim.api.nvim_create_autocmd('TabEnter', {
        group = group,
        callback = function()
            if vim.t.diffsplit_resized then
                equalize()
            end
        end,
    })
end

-- Open the diff tab for the current buffer against `ref` (default: the shared base).
-- Returns true when the tab opened.
function M.open(ref)
    local path = git.buf_path(0)
    if not path then
        err('not a file buffer')
        return false
    end
    local lines, label
    if git.tracked(path) then
        ref = (ref and ref ~= '') and ref or base.get()
        local reason
        lines, reason = git.show(path, ref)
        if not lines then
            err(reason ~= '' and reason or ('no ' .. ref .. ' version of this file'))
            return false
        end
        label = base.label(ref)
    elseif vim.fn.filereadable(path) == 1 then
        lines = vim.fn.readfile(path)
        label = 'saved'
    else
        err('no git version or saved file to compare with')
        return false
    end

    local ft = vim.bo.filetype
    local src_buf = vim.api.nvim_get_current_buf()
    local from = vim.api.nvim_get_current_tabpage()

    vim.cmd('tab split')
    vim.t.diffsplit_buf = -1
    vim.t.diffsplit_src = src_buf
    vim.t.diffsplit_from = from
    local src_win = vim.api.nvim_get_current_win()
    vim.t.diffsplit_src_win = src_win
    vim.cmd('diffthis')
    vim.wo[src_win].foldenable = false

    vim.cmd('leftabove vnew')
    local copy = vim.api.nvim_get_current_buf()
    local copy_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(copy, 0, -1, false, lines)
    local bo = vim.bo[copy]
    bo.buftype = 'nofile'
    bo.bufhidden = 'wipe'
    bo.swapfile = false
    bo.buflisted = false
    bo.modifiable = false
    bo.filetype = ft
    pcall(vim.api.nvim_buf_set_name, copy, '[' .. label .. '] ' .. vim.fn.fnamemodify(path, ':t'))
    vim.cmd('diffthis')
    vim.wo[copy_win].foldenable = false
    vim.t.diffsplit_buf = copy

    vim.api.nvim_create_autocmd('BufWipeout', {
        buffer = copy,
        once = true,
        callback = function()
            vim.schedule(function()
                finish(src_win, src_buf, copy)
            end)
        end,
    })
    vim.keymap.set('n', 'q', function()
        M.close()
    end, { buffer = copy, silent = true, desc = Q_DESC })

    vim.api.nvim_set_current_win(src_win)
    hook_resize()
    vim.keymap.set('n', 'q', q_expr, { buffer = src_buf, expr = true, silent = true, desc = Q_DESC })
    return true
end

return M
