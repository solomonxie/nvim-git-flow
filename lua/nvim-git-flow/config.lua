local M = {}

M.defaults = {
    -- the ref every view diffs against at startup; :ChangeGitDiffBase changes it for the session
    -- ('' or nil -> where the current branch forked from main/master, re-picked per repo)
    base = 'HEAD',
    signs = {
        enabled = true,
        -- one bar char per kind; colored by GitFlowAdd / GitFlowChange / GitFlowDelete
        text = { add = '▎', change = '▎', delete = '▁', topdelete = '▔', changedelete = '▎' },
        -- also color the line number of changed lines
        numhl = true,
        -- whole-line background tint (GitFlowAddLine / GitFlowChangeLine), off by default
        linehl = false,
        -- re-diff this long after the last edit
        debounce_ms = 200,
        -- skip a buffer with more lines than this, or a line with more characters than this
        max_size = 20000,
        -- a file opened through a symlink whose real file is in another repo (or none): false
        -- shows no signs; true diffs it in the repo it really lives in
        follow_links = false,
    },
    preview = {
        border = 'rounded',
    },
    blame = {
        -- virtual-text highlight
        hl = 'Comment',
    },
    -- :GitHunkUndo asks y/n first; undo_hunk({ confirm = false }) skips it for one call
    undo = {
        confirm = true,
    },
    -- No keymaps: the plugin maps no keys. Map the commands or the Lua functions in your own config.
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
    return M.options
end

return M
