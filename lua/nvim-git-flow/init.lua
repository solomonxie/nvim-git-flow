-- nvim-git-flow: git signs, hunk preview/stage/undo, a side-by-side diff tab, line blame and
-- remote links, all diffing against one shared base (see base.lua).

local config = require('nvim-git-flow.config')

local M = {}

M._configured = false

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
end

return M
