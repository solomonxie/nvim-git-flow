-- nvim-git-flow: git signs, hunk preview/stage/undo, a side-by-side diff tab, line blame and
-- remote links, all diffing against one shared base (see base.lua).

local config = require('nvim-git-flow.config')

local M = {}

M._configured = false

local function map(key, rhs, desc)
    if key then
        vim.keymap.set('n', key, rhs, { silent = true, desc = desc })
    end
end

function M.setup(opts)
    local o = config.setup(opts)
    M._configured = true

    require('nvim-git-flow.base').setup(o.base)
    require('nvim-git-flow.signs').setup()
    require('nvim-git-flow.blame').setup()

    local group = vim.api.nvim_create_augroup('NvimGitFlow', { clear = true })
    vim.api.nvim_create_autocmd('BufEnter', {
        group = group,
        callback = function()
            require('nvim-git-flow.base').on_buf_enter()
        end,
    })

    local k = o.keymaps
    local signs = function()
        return require('nvim-git-flow.signs')
    end
    map(k.hunk_next, function() signs().next_hunk() end, 'Git: next hunk')
    map(k.hunk_prev, function() signs().prev_hunk() end, 'Git: previous hunk')
    map(k.hunk_preview, function() signs().preview_hunk() end, 'Git: preview hunk')
    map(k.hunk_stage, function() signs().stage_hunk() end, 'Git: stage hunk')
    map(k.hunk_undo, function() signs().undo_hunk() end, 'Git: undo hunk')
    map(k.hunk_fold, function() signs().toggle_fold() end, 'Git: fold all but hunks')
    map(k.diff_split, function() require('nvim-git-flow.diffsplit').open() end, 'Git: diff tab vs base')
    map(k.blame_toggle, function() require('nvim-git-flow.blame').toggle() end, 'Git: toggle line blame')
end

return M
