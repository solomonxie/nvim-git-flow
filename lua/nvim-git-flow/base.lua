-- The diff base: the one ref every git view diffs against (signs, :DiffSplit, and other plugins).
-- Kept in g:git_diff_base so plugins that don't know this one can read it, and announced with
-- `doautocmd User GitDiffBaseChanged` whenever it changes.
--
-- :ChangeGitDiffBase          -> where this branch forked from main (fallback master), so views show
--                                the whole branch like a PR; re-picked per repo on BufEnter
-- :ChangeGitDiffBase <ref>    -> any branch/tag/commit, e.g. HEAD~3, origin/develop
-- :ChangeGitDiffBase HEAD     -> uncommitted changes only

local git = require('nvim-git-flow.git')

local M = {}

local auto = false      -- following the fork point, re-picked per repo
local auto_repo = nil   -- repo the auto pick was made for

-- Current base ref (a full commit id, or a ref name such as HEAD).
function M.get()
    local ref = vim.g.git_diff_base
    return (ref and ref ~= '') and ref or 'HEAD'
end

-- Short label for display: first 8 chars of a commit id, a ref name as is.
function M.label(ref)
    ref = ref or M.get()
    return ref:match('^%x+$') and #ref >= 40 and ref:sub(1, 8) or ref
end

local function changed()
    vim.api.nvim_exec_autocmds('User', { pattern = 'GitDiffBaseChanged', modeline = false })
end

local function dir_here()
    return git.buf_path(0) and vim.fs.dirname(git.buf_path(0)) or vim.fn.getcwd()
end

-- Point the base at `ref` ('' = fork point of the current branch from main/master).
-- quiet: no messages. Returns true when the base was set.
function M.set(ref, quiet)
    local dir = dir_here()
    auto = ref == nil or ref == ''
    local base, label
    if auto then
        local trunk
        for _, candidate in ipairs({ 'main', 'master', 'origin/main', 'origin/master' }) do
            if git.rev_parse(dir, candidate) then
                trunk = candidate
                break
            end
        end
        if not trunk then
            if not quiet then
                vim.notify('ChangeGitDiffBase: no main/master branch found', vim.log.levels.ERROR)
            end
            return false
        end
        local out, code = git.run(dir, { 'merge-base', 'HEAD', trunk })
        base = code == 0 and vim.trim(out) or nil
        label = 'merge-base with ' .. trunk
        auto_repo = git.root(dir)
    else
        base = git.rev_parse(dir, ref)
        label = ref
    end
    if not base or base == '' then
        if not quiet then
            vim.notify('ChangeGitDiffBase: invalid ref: ' .. (ref or ''), vim.log.levels.ERROR)
        end
        return false
    end
    -- keep HEAD symbolic, so a commit moves the base along with it
    vim.g.git_diff_base = ref == 'HEAD' and 'HEAD' or base
    changed()
    if not quiet then
        vim.api.nvim_echo({ { 'Git diff base: ' .. label .. ' (' .. base:sub(1, 8) .. ')' } }, false, {})
    end
    return true
end

-- BufEnter in auto mode: a buffer of another repo gets that repo's fork point.
function M.on_buf_enter()
    if not auto or vim.bo.buftype ~= '' then
        return
    end
    local path = git.buf_path(0)
    if not path then
        return
    end
    local root = git.root(path)
    if not root or root == auto_repo then
        return
    end
    vim.g.git_diff_base = 'HEAD'  -- no main/master here: don't keep another repo's base
    M.set('', true)
end

-- Completion for ref arguments: HEAD plus every branch, remote branch and tag.
function M.complete(arglead)
    local out = git.run(dir_here(), { 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes', 'refs/tags' })
    local refs = vim.list_extend({ 'HEAD' }, vim.split(out, '\n', { trimempty = true }))
    return vim.tbl_filter(function(r)
        return vim.startswith(r, arglead)
    end, refs)
end

function M.setup(start_ref)
    if start_ref == nil or start_ref == '' then
        auto = true
    elseif vim.g.git_diff_base == nil or vim.g.git_diff_base == '' then
        vim.g.git_diff_base = start_ref
    end
end

return M
