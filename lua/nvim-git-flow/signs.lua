-- Git signs: the sign column shows where the buffer differs from the diff base (base.lua), plus
-- hunk jumping, preview, stage, undo, fold and location list. Replaces vim-gitgutter.
--
-- The base text comes from one async `git show` per buffer and ref, cached until a write, a focus
-- back, a shell command or a base change, so typing only re-runs vim.diff in memory.

local config = require('nvim-git-flow.config')
local git = require('nvim-git-flow.git')
local base = require('nvim-git-flow.base')

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('nvim-git-flow.signs')
local group = nil

-- Per buffer: { key = path\0ref the base is for, status = 'pending'|'ready', base = see load_base,
-- gen = request counter, hunks = {...}, tick = changedtick the hunks are for, near = fold lookup,
-- timer = debounce timer }
local state = {}

-- Saved fold options per window while toggle_fold() is on.
local folded = {}

local preview = nil -- { win, buf, src, group, focusing }

-- How many unchanged lines toggle_fold() keeps open around each hunk.
local FOLD_CONTEXT = 3

local KINDS = {
    add = { hl = 'GitFlowAdd', nr = 'GitFlowAddNr', line = 'GitFlowAddLine' },
    change = { hl = 'GitFlowChange', nr = 'GitFlowChangeNr', line = 'GitFlowChangeLine' },
    changedelete = { hl = 'GitFlowChangeDelete', nr = 'GitFlowChangeNr', line = 'GitFlowChangeLine' },
    -- removed lines don't exist in the buffer: tinting the line next to them would mislead
    delete = { hl = 'GitFlowDelete', nr = 'GitFlowDeleteNr' },
    topdelete = { hl = 'GitFlowDelete', nr = 'GitFlowDeleteNr' },
}

local function opts()
    return config.options.signs
end

local function echo(msg, hl)
    api.nvim_echo({ { msg, hl } }, false, {})
end

local function define_highlights()
    local set = function(name, val)
        val.default = true -- a colorscheme or the user's own :highlight wins
        api.nvim_set_hl(0, name, val)
    end
    set('GitFlowAdd', { fg = 'Green', ctermfg = 'Green' })
    set('GitFlowChange', { fg = 'Yellow', ctermfg = 'Yellow' })
    set('GitFlowDelete', { fg = 'Red', ctermfg = 'Red' })
    set('GitFlowChangeDelete', { link = 'GitFlowChange' })
    set('GitFlowAddNr', { fg = 'Green', ctermfg = 'Green' })
    set('GitFlowChangeNr', { fg = 'Yellow', ctermfg = 'Yellow' })
    set('GitFlowDeleteNr', { fg = 'Red', ctermfg = 'Red' })
    set('GitFlowAddLine', { bg = '#1a3a24', ctermbg = 22 })
    set('GitFlowChangeLine', { bg = '#3a3a1a', ctermbg = 58 })
end

---------------------------------------------------------------------------------------------------
-- Loading the base text
---------------------------------------------------------------------------------------------------

-- Run git in `dir`, calling cb(result) right away (sync) or on the main loop once git exits.
local function git_cmd(dir, args, sync, cb)
    local cmd = vim.list_extend({ 'git', '-C', dir }, args)
    if sync then
        cb(vim.system(cmd, { text = true }):wait())
    else
        vim.system(cmd, { text = true }, vim.schedule_wrap(cb))
    end
end

local function split_lines(text)
    local lines = vim.split(text, '\n', { plain = true })
    if lines[#lines] == '' then
        table.remove(lines)
    end
    return lines
end

-- What `path` is diffed against at `ref`. done() gets one of:
--   { kind = 'none' }                       outside git, or ignored: no signs
--   { kind = 'untracked', lines = {} }      in a repo but not tracked: everything is added
--   { kind = 'tracked', lines = {...} }     the file at ref ({} when it's new since ref)
-- Same steps as git.tracked() + git.show(), but async so opening a file never waits on git.
local function load_base(path, ref, sync, done)
    local dir = vim.fs.dirname(path)
    if vim.fn.isdirectory(dir) == 0 then
        return done({ kind = 'none' }) -- a new file in a folder not created yet
    end
    git_cmd(dir, { 'ls-files', '--full-name', '--', path }, sync, function(ls)
        if ls.code ~= 0 then
            return done({ kind = 'none' })
        end
        local rel = vim.trim(ls.stdout or '')
        if rel == '' then
            git_cmd(dir, { 'check-ignore', '-q', '--', path }, sync, function(ign)
                done(ign.code == 0 and { kind = 'none' } or { kind = 'untracked', lines = {} })
            end)
            return
        end
        git_cmd(dir, { 'show', ref .. ':' .. rel }, sync, function(show)
            -- a failing show means the file isn't in that ref yet: it is all new since the base
            local lines = show.code == 0 and split_lines(show.stdout or '') or {}
            done({ kind = 'tracked', lines = lines })
        end)
    end)
end

---------------------------------------------------------------------------------------------------
-- Hunks
---------------------------------------------------------------------------------------------------

local function to_text(lines)
    if #lines == 0 then
        return ''
    end
    return table.concat(lines, '\n') .. '\n'
end

-- Buffer lines as they'd be written: an empty buffer is an empty file, not one blank line.
local function buf_lines(buf)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 1 and lines[1] == '' then
        return {}
    end
    return lines
end

-- Hunks turning old_lines into new_lines, in buffer order (see get_hunks for the shape).
local function compute_hunks(old_lines, new_lines)
    local hunks = {}
    local indices = vim.diff(to_text(old_lines), to_text(new_lines), {
        result_type = 'indices',
        algorithm = 'histogram',
    })
    for _, d in ipairs(indices) do
        local old_start, old_count, new_start, new_count = d[1], d[2], d[3], d[4]
        local kind = old_count == 0 and 'add' or new_count == 0 and 'delete' or 'change'
        -- for a zero count vim.diff already gives the line the hunk sits below, as get_hunks wants
        hunks[#hunks + 1] = {
            type = kind,
            start = new_start,
            count = new_count,
            old_start = old_start,
            old_count = old_count,
            old_lines = vim.list_slice(old_lines, old_start, old_start + old_count - 1),
            new_lines = vim.list_slice(new_lines, new_start, new_start + new_count - 1),
        }
    end
    return hunks
end

-- The buffer line a hunk's sign sits on and jumps go to.
local function hunk_line(h)
    return math.max(h.start, 1)
end

local function hunk_at(hunks, lnum)
    for _, h in ipairs(hunks) do
        if h.type == 'delete' then
            if hunk_line(h) == lnum then
                return h
            end
        elseif lnum >= h.start and lnum < h.start + h.count then
            return h
        end
    end
    return nil
end

local function draw(buf, hunks)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local o = opts()
    local kinds = {}
    for _, h in ipairs(hunks) do
        if h.type == 'delete' then
            local l = hunk_line(h)
            local prev = kinds[l]
            if prev == 'change' or prev == 'changedelete' then
                kinds[l] = 'changedelete'
            elseif not prev then
                kinds[l] = h.start == 0 and 'topdelete' or 'delete'
            end
        else
            for l = h.start, h.start + h.count - 1 do
                kinds[l] = h.type
            end
            -- old had more lines than are left: mark that some were removed, too
            if h.type == 'change' and h.old_count > h.count then
                kinds[h.start + h.count - 1] = 'changedelete'
            end
        end
    end
    local line_count = api.nvim_buf_line_count(buf)
    for l, kind in pairs(kinds) do
        if l <= line_count then
            local k = KINDS[kind]
            api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
                sign_text = o.text[kind] or o.text.change,
                sign_hl_group = k.hl,
                number_hl_group = o.numhl and k.nr or nil,
                line_hl_group = o.linehl and k.line or nil,
                -- low, so diagnostic and other signs win the column
                priority = 6,
            })
        end
    end
end

-- Lines toggle_fold() leaves open: every hunk line plus FOLD_CONTEXT around it.
local function near_lines(hunks)
    local near = {}
    for _, h in ipairs(hunks) do
        local first = hunk_line(h)
        local last = math.max(first, h.start + h.count - 1)
        for l = first - FOLD_CONTEXT, last + FOLD_CONTEXT do
            near[l] = true
        end
    end
    return near
end

local function too_big(buf, lines)
    local o = opts()
    if #lines > o.max_lines then
        return true
    end
    for _, line in ipairs(lines) do
        if #line > o.max_line_len then
            return true
        end
    end
    return false
end

local function clear(buf, st)
    if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    if st then
        st.hunks, st.near = {}, {}
        st.tick = api.nvim_buf_is_valid(buf) and api.nvim_buf_get_changedtick(buf) or nil
    end
end

-- Re-diff the buffer against its loaded base and redraw. Returns the hunks.
local function update(buf, st)
    local lines = buf_lines(buf)
    if st.base.kind == 'none' or too_big(buf, lines) then
        clear(buf, st)
        return st.hunks
    end
    st.hunks = compute_hunks(st.base.lines, lines)
    st.near = near_lines(st.hunks)
    st.tick = api.nvim_buf_get_changedtick(buf)
    draw(buf, st.hunks)
    return st.hunks
end

local function skip(buf)
    return vim.bo[buf].buftype ~= ''
        or vim.bo[buf].binary
        or vim.b[buf].bigfile
        or api.nvim_buf_line_count(buf) > opts().max_lines
end

---------------------------------------------------------------------------------------------------
-- Refreshing
---------------------------------------------------------------------------------------------------

local function state_of(buf)
    local st = state[buf]
    if not st then
        st = { gen = 0, hunks = {}, near = {} }
        state[buf] = st
    end
    return st
end

local function resolve_buf(buf)
    return (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
end

-- Recompute and redraw the signs of `buf`. Fetches the base only when it isn't cached for this
-- path and ref. opts.sync: run git right here instead of in the background (tests, and actions
-- that need the hunks now). Returns the hunks when they're ready, else nil.
function M.refresh(buf, o)
    buf = resolve_buf(buf)
    o = o or {}
    if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
        return nil
    end
    local st = state_of(buf)
    local path = git.buf_path(buf)
    if not opts().enabled or not path or skip(buf) then
        clear(buf, st)
        return st.hunks
    end
    local key = path .. '\0' .. base.get()
    if st.key == key and st.status == 'ready' then
        return update(buf, st)
    end
    if st.key == key and st.status == 'pending' and not o.sync then
        return nil -- the request in flight will draw
    end
    st.key, st.status = key, 'pending'
    st.gen = st.gen + 1
    local gen = st.gen
    local result
    load_base(path, base.get(), o.sync, function(res)
        -- the buffer may be gone, or renamed / re-based / invalidated while git ran
        if state[buf] ~= st or st.gen ~= gen or not api.nvim_buf_is_valid(buf) then
            return
        end
        st.base, st.status = res, 'ready'
        result = update(buf, st)
    end)
    return result
end

-- Forget the cached base of `buf` (it may have changed outside the buffer) and refresh.
function M.invalidate(buf)
    buf = resolve_buf(buf)
    local st = state[buf]
    if st then
        st.key, st.status = nil, nil
        st.gen = st.gen + 1 -- drop any answer still in flight
    end
    M.refresh(buf)
end

local function invalidate_all(visible_only)
    local bufs = {}
    if visible_only then
        for _, win in ipairs(api.nvim_list_wins()) do
            bufs[api.nvim_win_get_buf(win)] = true
        end
    end
    for buf, st in pairs(state) do
        if visible_only and not bufs[buf] then
            -- hidden buffers re-fetch on their next BufEnter
            st.key, st.status = nil, nil
            st.gen = st.gen + 1
        else
            M.invalidate(buf)
        end
    end
end

local function debounce(buf)
    local st = state[buf]
    if not st or not st.status then
        return -- never attached (skipped or not a file): nothing to re-diff
    end
    if not st.timer then
        st.timer = vim.uv.new_timer()
    end
    st.timer:stop()
    st.timer:start(opts().debounce_ms, 0, vim.schedule_wrap(function()
        if state[buf] == st then
            M.refresh(buf)
        end
    end))
end

local function detach(buf)
    local st = state[buf]
    if st and st.timer then
        st.timer:stop()
        st.timer:close()
    end
    state[buf] = nil
end

-- Hunks of `buf` against the base, as last loaded (re-diffed first if the buffer changed since).
-- Each: { type = 'add'|'change'|'delete', start, count, old_start, old_count, old_lines, new_lines }
-- start is the first buffer line (1-based); for a delete the line above, 0 at the top of the file.
function M.get_hunks(buf)
    buf = resolve_buf(buf)
    local st = state[buf]
    if not st then
        return {}
    end
    if st.status == 'ready' and api.nvim_buf_is_valid(buf) and st.tick ~= api.nvim_buf_get_changedtick(buf) then
        update(buf, st)
    end
    return st.hunks
end

-- Up to date hunks of the current buffer for an action: fetches the base synchronously if needed.
local function current_hunks()
    local buf = api.nvim_get_current_buf()
    return M.refresh(buf, { sync = true }) or M.get_hunks(buf), buf
end

-- { added, changed, removed } line counts, for statuslines.
function M.hunk_summary(buf)
    local added, changed, removed = 0, 0, 0
    for _, h in ipairs(M.get_hunks(buf)) do
        if h.type == 'add' then
            added = added + h.count
        elseif h.type == 'delete' then
            removed = removed + h.old_count
        else
            local both = math.min(h.count, h.old_count)
            changed = changed + both
            added = added + h.count - both
            removed = removed + h.old_count - both
        end
    end
    return { added = added, changed = changed, removed = removed }
end

---------------------------------------------------------------------------------------------------
-- Jumping
---------------------------------------------------------------------------------------------------

local function jump(forward)
    local hunks = current_hunks()
    if #hunks == 0 then
        echo('No hunks', 'WarningMsg')
        return
    end
    local line = api.nvim_win_get_cursor(0)[1]
    local wrapped = false
    for _ = 1, vim.v.count1 do
        local target
        if forward then
            for _, h in ipairs(hunks) do
                if hunk_line(h) > line then
                    target = hunk_line(h)
                    break
                end
            end
            if not target then
                target, wrapped = hunk_line(hunks[1]), true
            end
        else
            for i = #hunks, 1, -1 do
                if hunk_line(hunks[i]) < line then
                    target = hunk_line(hunks[i])
                    break
                end
            end
            if not target then
                target, wrapped = hunk_line(hunks[#hunks]), true
            end
        end
        line = target
    end
    vim.cmd("normal! m'") -- so <C-o> comes back
    api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd('normal! ^zv')
    if wrapped then
        echo(forward and 'Wrapped to the first hunk' or 'Wrapped to the last hunk', 'WarningMsg')
    end
end

function M.next_hunk()
    jump(true)
end

function M.prev_hunk()
    jump(false)
end

---------------------------------------------------------------------------------------------------
-- Preview
---------------------------------------------------------------------------------------------------

local function hunk_header(h)
    return ('@@ -%d,%d +%d,%d @@'):format(h.old_start, h.old_count, h.start, h.count)
end

local function diff_lines(h)
    local out = { hunk_header(h) }
    for _, l in ipairs(h.old_lines) do
        out[#out + 1] = '-' .. l
    end
    for _, l in ipairs(h.new_lines) do
        out[#out + 1] = '+' .. l
    end
    return out
end

local function close_preview()
    local p = preview
    preview = nil
    if not p then
        return
    end
    pcall(api.nvim_del_augroup_by_id, p.group)
    if api.nvim_win_is_valid(p.win) then
        api.nvim_win_close(p.win, true)
    end
end

function M.preview_hunk()
    local p = preview
    if p and api.nvim_win_is_valid(p.win) then
        if api.nvim_get_current_win() == p.win then
            close_preview()
            return
        end
        if api.nvim_get_current_buf() == p.src then
            -- second press: step into the float to scroll or copy from it
            p.focusing = true
            api.nvim_set_current_win(p.win)
            p.focusing = false
            return
        end
    end
    close_preview()

    local hunks, src = current_hunks()
    local h = hunk_at(hunks, api.nvim_win_get_cursor(0)[1])
    if not h then
        echo('No hunk under the cursor', 'WarningMsg')
        return
    end
    local lines = diff_lines(h)
    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    local fbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
    vim.bo[fbuf].modifiable = false
    vim.bo[fbuf].bufhidden = 'wipe'
    vim.bo[fbuf].filetype = 'diff'
    local win = api.nvim_open_win(fbuf, false, {
        relative = 'cursor',
        row = 1,
        col = 0,
        width = math.max(1, math.min(width, vim.o.columns - 4)),
        height = math.max(1, math.min(#lines, math.floor(vim.o.lines / 2))),
        style = 'minimal',
        border = config.options.preview.border,
        focusable = true,
    })
    vim.wo[win].wrap = false
    vim.wo[win].foldenable = false

    local aug = api.nvim_create_augroup('nvim-git-flow.preview', { clear = true })
    preview = { win = win, buf = fbuf, src = src, group = aug, focusing = false }
    api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufLeave' }, {
        group = aug,
        buffer = src,
        callback = function()
            if preview and not preview.focusing then
                close_preview()
            end
        end,
    })
    -- once focused, leaving the float ends the preview
    -- (scheduled: a window can't be closed from inside its own WinLeave)
    api.nvim_create_autocmd('WinLeave', { group = aug, buffer = fbuf, callback = function()
        vim.schedule(close_preview)
    end })
    for _, key in ipairs({ 'q', '<Esc>' }) do
        vim.keymap.set('n', key, close_preview, { buffer = fbuf, nowait = true, silent = true })
    end
end

---------------------------------------------------------------------------------------------------
-- Stage and undo
---------------------------------------------------------------------------------------------------

-- An untracked file has one hunk, the whole buffer: put the buffer's text in the index as a new
-- file, so unsaved edits are staged as they read.
local function stage_new_file(buf, path, root)
    if not vim.startswith(path, root .. '/') then
        echo('Stage: cannot place ' .. path .. ' in ' .. root, 'ErrorMsg')
        return
    end
    local rel = path:sub(#root + 2)
    local out, code, err = git.run(root, { 'hash-object', '-w', '--stdin' }, to_text(buf_lines(buf)))
    if code == 0 then
        local mode = vim.fn.executable(path) == 1 and '100755' or '100644'
        out, code, err = git.run(root, { 'update-index', '--add', '--cacheinfo', mode .. ',' .. vim.trim(out) .. ',' .. rel })
    end
    if code ~= 0 then
        echo('Stage failed: ' .. vim.trim(err), 'ErrorMsg')
        return
    end
    echo('Staged new file ' .. rel)
end

-- Stages against the index whatever the diff base is: the patch is the index version vs the
-- buffer at the cursor, which is the only patch `git apply --cached` can take. With base HEAD and
-- nothing staged yet that's exactly the hunk the signs show.
function M.stage_hunk()
    local buf = api.nvim_get_current_buf()
    local path = git.buf_path(buf)
    local root = path and git.root(path)
    if not root then
        echo('Stage: not a file in a git repo', 'WarningMsg')
        return
    end
    local rel = git.tracked(path)
    if not rel then
        stage_new_file(buf, path, root)
        M.invalidate(buf)
        return
    end
    local index = git.show(path, '') -- `git show :rel`
    if not index then
        echo('Stage: no index version of ' .. rel, 'ErrorMsg')
        return
    end
    local h = hunk_at(compute_hunks(index, buf_lines(buf)), api.nvim_win_get_cursor(0)[1])
    if not h then
        echo('No unstaged hunk under the cursor', 'WarningMsg')
        return
    end
    local patch = {
        'diff --git a/' .. rel .. ' b/' .. rel,
        '--- a/' .. rel,
        '+++ b/' .. rel,
    }
    -- the +side has to say where the lines land in the index once only this hunk is in, which
    -- differs from the buffer's numbering when other hunks above stay unstaged
    local new_start = h.old_start
    if h.old_count == 0 then
        new_start = h.old_start + 1
    elseif h.count == 0 then
        new_start = h.old_start - 1
    end
    patch[#patch + 1] = ('@@ -%d,%d +%d,%d @@'):format(h.old_start, h.old_count, new_start, h.count)
    vim.list_extend(patch, vim.list_slice(diff_lines(h), 2))
    -- zero context lines, so --unidiff-zero; git places the hunk by its line numbers
    local _, code, err = git.run(root, { 'apply', '--cached', '--unidiff-zero', '--whitespace=nowarn', '-' },
        table.concat(patch, '\n') .. '\n')
    if code ~= 0 then
        echo('Stage failed: ' .. vim.trim(err), 'ErrorMsg')
        return
    end
    echo('Staged ' .. hunk_header(h))
    M.invalidate(buf)
end

-- Put the base's lines back in place of the hunk under the cursor, as one undo step.
function M.undo_hunk()
    local hunks, buf = current_hunks()
    local h = hunk_at(hunks, api.nvim_win_get_cursor(0)[1])
    if not h then
        echo('No hunk under the cursor', 'WarningMsg')
        return
    end
    if h.type == 'delete' then
        api.nvim_buf_set_lines(buf, h.start, h.start, false, h.old_lines)
    else
        -- a buffer can't have zero lines: undoing an all-added buffer leaves one empty line
        api.nvim_buf_set_lines(buf, h.start - 1, h.start - 1 + h.count, false, h.old_lines)
    end
    local last = api.nvim_buf_line_count(buf)
    api.nvim_win_set_cursor(0, { math.min(math.max(h.start, 1), last), 0 })
    M.refresh(buf)
end

---------------------------------------------------------------------------------------------------
-- Fold, location list, toggle
---------------------------------------------------------------------------------------------------

-- foldexpr while toggle_fold() is on: unchanged stretches away from any hunk fold away.
function M.foldexpr()
    local st = state[api.nvim_get_current_buf()]
    return (st and st.near[vim.v.lnum]) and 0 or 1
end

local FOLD_OPTS = { 'foldmethod', 'foldexpr', 'foldlevel', 'foldenable', 'foldminlines' }

function M.toggle_fold()
    local win = api.nvim_get_current_win()
    local saved = folded[win]
    if saved then
        for _, name in ipairs(FOLD_OPTS) do
            vim.wo[win][name] = saved[name]
        end
        folded[win] = nil
        -- going back to manual keeps the folds the expr made; drop them (the window's own manual
        -- folds were already replaced when the expr took over)
        if saved.foldmethod == 'manual' then
            vim.cmd('normal! zE')
        end
        return
    end
    current_hunks()
    saved = {}
    for _, name in ipairs(FOLD_OPTS) do
        saved[name] = vim.wo[win][name]
    end
    folded[win] = saved
    vim.wo[win].foldexpr = "v:lua.require'nvim-git-flow.signs'.foldexpr()"
    vim.wo[win].foldmethod = 'expr'
    vim.wo[win].foldlevel = 0
    vim.wo[win].foldminlines = 0
    vim.wo[win].foldenable = true
    vim.cmd('normal! zx')
end

function M.to_loclist()
    local hunks, buf = current_hunks()
    local items = {}
    for _, h in ipairs(hunks) do
        local text
        if h.type == 'delete' then
            text = ('[-] %d line%s removed'):format(h.old_count, h.old_count == 1 and '' or 's')
        else
            text = (h.type == 'add' and '[+] ' or '[~] ') .. vim.trim(h.new_lines[1] or '')
        end
        items[#items + 1] = { bufnr = buf, lnum = hunk_line(h), col = 1, text = text }
    end
    vim.fn.setloclist(0, {}, ' ', { title = 'Git hunks vs ' .. base.label(), items = items })
    if #items == 0 then
        echo('No hunks', 'WarningMsg')
        return
    end
    vim.cmd('lopen')
end

local function each_loaded(fn)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) then
            fn(buf)
        end
    end
end

function M.toggle()
    local o = opts()
    o.enabled = not o.enabled
    if o.enabled then
        each_loaded(M.refresh)
        echo('Git signs on')
    else
        for buf in pairs(state) do
            clear(buf)
            detach(buf)
        end
        echo('Git signs off')
    end
end

---------------------------------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------------------------------

function M.setup()
    define_highlights()
    group = api.nvim_create_augroup('NvimGitFlowSigns', { clear = true })
    local au = function(events, cb, pattern)
        api.nvim_create_autocmd(events, { group = group, pattern = pattern, callback = cb })
    end
    au('ColorScheme', define_highlights)
    au({ 'BufReadPost', 'BufEnter' }, function(a)
        M.refresh(a.buf)
    end)
    -- a write can be what makes a new file trackable, and keeps a `git add` from elsewhere honest
    au('BufWritePost', function(a)
        M.invalidate(a.buf)
    end)
    -- a commit, checkout or stash outside nvim (another terminal, :!git, a terminal buffer)
    au({ 'FocusGained', 'ShellCmdPost', 'TermLeave' }, function()
        invalidate_all(true)
    end)
    au({ 'TextChanged', 'TextChangedI' }, function(a)
        debounce(a.buf)
    end)
    au('User', function()
        invalidate_all(false)
    end, 'GitDiffBaseChanged')
    au({ 'BufWipeout', 'BufDelete' }, function(a)
        detach(a.buf)
    end)
    au('WinClosed', function(a)
        folded[tonumber(a.match)] = nil
    end)

    -- buffers already open when setup runs late (lazy loading)
    if opts().enabled then
        each_loaded(function(buf)
            if vim.bo[buf].buftype == '' then
                M.refresh(buf)
            end
        end)
    end
end

return M
