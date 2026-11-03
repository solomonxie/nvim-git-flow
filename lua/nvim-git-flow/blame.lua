-- Blame of the cursor line as end-of-line virtual text ("author, N days ago - summary").
-- The whole file is blamed once in the background per buffer and changedtick, so moving the
-- cursor is instant. Blamed from the buffer's current text (--contents -), so unsaved edits keep
-- the lines right; re-blamed after edits. Hidden in insert mode. Off until :GitBlameToggle.

local config = require('nvim-git-flow.config')
local git = require('nvim-git-flow.git')

local M = {}

local ns = vim.api.nvim_create_namespace('nvim_git_flow_blame')
local group = nil
local cache = {}    -- bufnr -> { tick = changedtick blamed, lines = { "author, N days ago - summary", ... } }
local pending = {}  -- bufnr -> changedtick of the blame job running for it

local NOT_COMMITTED = 'Not committed yet'

-- `git blame --line-porcelain` output -> one display string per line, in order.
-- `now`: unix time the ages are counted from (default: os.time()).
function M.parse_porcelain(stdout, now)
    now = now or os.time()
    local lines, info = {}, {}
    -- one block per line: "<commit id> <line numbers>", header fields, then a tab and the line
    for line in stdout:gmatch('[^\n]+') do
        if line:sub(1, 1) == '\t' then
            if info.commit:match('^0+$') then
                -- uncommitted lines get the all-zero commit id
                table.insert(lines, NOT_COMMITTED)
            else
                local days = math.floor((now - tonumber(info['author-time'])) / 86400)
                table.insert(lines, string.format('%s, %s - %s', info.author,
                    days == 0 and 'today' or days .. ' days ago', info.summary))
            end
        else
            local key, value = line:match('^(%S+) ?(.*)')
            if key and #key == 40 and key:match('^%x+$') then
                info.commit = key
            elseif key then
                info[key] = value
            end
        end
    end
    return lines
end

local function show()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local blamed = cache[buf]
    if not blamed or vim.fn.mode() ~= 'n' then
        return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    -- a line missing from the blame: a file git doesn't track yet
    local text = blamed.lines[row] or NOT_COMMITTED
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        virt_text = { { '  ' .. text, config.options.blame.hl } },
        virt_text_pos = 'eol',
    })
end

local function blame()
    local buf = vim.api.nvim_get_current_buf()
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local path = git.buf_path(buf)
    if not path or vim.b[buf].bigfile or vim.fn.filereadable(path) == 0 then
        return
    end
    if (cache[buf] and cache[buf].tick == tick) or pending[buf] == tick then
        return
    end
    pending[buf] = tick
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
    local cmd = { 'git', '-C', vim.fs.dirname(path), 'blame', '--line-porcelain', '--contents', '-', '--', path }
    vim.system(cmd, { stdin = text, text = true }, vim.schedule_wrap(function(res)
        if pending[buf] == tick then
            pending[buf] = nil
        end
        if not group or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        -- untracked file: git says "no such path"; every line then shows as not committed
        if res.code ~= 0 and not (res.stderr or ''):match('no such path') then
            return
        end
        local stdout = res.code == 0 and res.stdout or ''
        cache[buf] = { tick = tick, lines = M.parse_porcelain(stdout) }
        if buf == vim.api.nvim_get_current_buf() then
            show()
        end
    end))
end

function M.enabled()
    return group ~= nil
end

function M.toggle()
    local on = group == nil
    if group then
        vim.api.nvim_del_augroup_by_id(group)
        group = nil
    end
    -- every buffer, not just this one: the others keep the text of the last line shown in them
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    cache, pending = {}, {}
    if on then
        group = vim.api.nvim_create_augroup('NvimGitFlowBlame', { clear = true })
        vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave', 'TextChanged' },
            { group = group, callback = blame })
        vim.api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter' }, { group = group, callback = show })
        vim.api.nvim_create_autocmd('BufWipeout', {
            group = group,
            callback = function(a)
                cache[a.buf], pending[a.buf] = nil, nil
            end,
        })
        blame()
    end
    return on
end

-- Nothing visible until toggled on.
function M.setup() end

return M
