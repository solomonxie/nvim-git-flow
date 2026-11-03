-- Links to the remote copy of a file, line, line range, folder or repo, built from the first
-- remote (ssh URLs rewritten to https), at the current branch, or the commit when HEAD is
-- detached. GitHub, GitLab and Bitbucket URL shapes; anything else gets the GitHub shape.
--
-- :GithubLink / :GithubLinkCurrentLine -> copy to the + register
-- :GitOpen                             -> open in the browser (the repo root when there's no file)
-- :OpenChangedFiles                    -> every file changed vs the diff base, as the arg list

local git = require('nvim-git-flow.git')

local M = {}

local function err(msg)
    vim.notify(msg, vim.log.levels.ERROR)
end

-- Remote URL as https: git@host:o/r.git, ssh://git@host/o/r.git, git+ssh://git@host/o/r -> https://host/o/r
function M.https(remote_url)
    local url = remote_url
    url = url:gsub('^git@([^:]*):', 'https://%1/')
    url = url:gsub('^ssh://git@', 'https://')
    url = url:gsub('^git%+ssh://git@', 'https://')
    url = url:gsub('/$', '')
    url = url:gsub('%.git$', '')
    return url
end

-- URL of `path` (a file or a folder) on the repo's first remote.
-- opts.line: add #L<line>; opts.line_end: make it a range #L<line>-L<line_end>
-- opts.kind: 'blob' (default) for a file, 'tree' for a folder.
-- Returns url, or nil, reason.
function M.remote_url(path, opts)
    opts = opts or {}
    if not path or path == '' then
        return nil, 'Current buffer is not a file'
    end
    path = vim.fn.resolve(vim.fn.fnamemodify(path, ':p')):gsub('/$', '')
    local kind = opts.kind or 'blob'

    local root = git.root(path)
    if not root or root == '' then
        return nil, 'Current file is not in a Git repository'
    end

    local remotes = vim.split(git.run(root, { 'remote' }), '\n', { trimempty = true })
    local remote = remotes[1]
    if not remote then
        return nil, 'No Git remote found'
    end
    local out, code = git.run(root, { 'remote', 'get-url', remote })
    out = vim.trim(out)
    if code ~= 0 or out == '' then
        return nil, 'Could not determine Git remote URL'
    end
    local remote_url = M.https(out)

    local branch, bcode = git.run(root, { 'symbolic-ref', '--short', '-q', 'HEAD' })
    branch = vim.trim(branch)
    if bcode ~= 0 or branch == '' then
        branch = vim.trim((git.run(root, { 'rev-parse', 'HEAD' })))
    end

    local relative = path == root and '' or path:sub(#root + 2)
    relative = relative:gsub(' ', '%%20')
    branch = branch:gsub(' ', '%%20')
    local host = (remote_url:match('^https?://[^/]*') or ''):lower()
    local url
    if host:find('gitlab%.') then
        url = remote_url .. '/-/' .. kind .. '/' .. branch .. '/' .. relative
    elseif host:find('bitbucket%.') then
        url = remote_url .. '/src/' .. branch .. '/' .. relative
    else
        -- github.com and anything else
        url = remote_url .. '/' .. kind .. '/' .. branch .. '/' .. relative
    end
    url = url:gsub('/$', '')

    if opts.line then
        url = url .. '#L' .. opts.line
        if opts.line_end and opts.line_end ~= opts.line then
            -- GitLab writes ranges #L3-7, GitHub (and the rest) #L3-L7
            url = url .. (host:find('gitlab%.') and '-' or '-L') .. opts.line_end
        end
    end
    return url
end

-- Copy the current file's URL to the + register; with_line adds the cursor line, or the
-- l1..l2 range when given (e.g. from a visual selection).
function M.copy(with_line, l1, l2)
    local opts = {}
    if with_line then
        if l1 and l2 and l1 ~= l2 then
            opts.line, opts.line_end = math.min(l1, l2), math.max(l1, l2)
        else
            opts.line = l1 or vim.api.nvim_win_get_cursor(0)[1]
        end
    end
    local url, reason = M.remote_url(git.buf_path(0), opts)
    if not url then
        err(reason)
        return nil
    end
    vim.fn.setreg('+', url)
    vim.api.nvim_echo({ { 'Copied Git remote link' } }, false, {})
    return url
end

-- Program that opens a URL here, or nil.
function M.browser()
    for _, prog in ipairs({ 'open', 'xdg-open', 'cmd.exe' }) do
        if vim.fn.executable(prog) == 1 then
            return prog
        end
    end
end

-- Open the current file on the remote; with no file (empty buffer, NERDTree...) the repo root
-- of the cwd. Echoes the URL when there's no browser opener.
function M.open()
    local path = git.buf_path(0)
    local url, reason
    if path then
        url, reason = M.remote_url(path)
    else
        local cwd = vim.fn.getcwd()
        url, reason = M.remote_url(git.root(cwd) or cwd, { kind = 'tree' })
    end
    if not url then
        err(reason)
        return nil
    end
    local prog = M.browser()
    if not prog then
        vim.api.nvim_echo({ { url } }, false, {})
        return url
    end
    local cmd = prog == 'cmd.exe' and { 'cmd.exe', '/c', 'start', '', url } or { prog, url }
    vim.fn.jobstart(cmd, { detach = true })
    vim.api.nvim_echo({ { 'Opened ' .. url } }, false, {})
    return url
end

-- Make every file changed vs the diff base (committed or not, still on disk) the arg list, and
-- edit the first. Returns the absolute paths.
function M.open_changed()
    local path = git.buf_path(0)
    local root = git.root(path or vim.fn.getcwd())
    if not root then
        err('Not in a Git repository')
        return {}
    end
    local base = require('nvim-git-flow.base').get()
    local out, code, stderr = git.run(root, { 'diff', '--name-only', base })
    if code ~= 0 then
        err('git diff ' .. base .. ': ' .. vim.trim(stderr))
        return {}
    end
    local files = {}
    for _, rel in ipairs(vim.split(out, '\n', { trimempty = true })) do
        local abs = root .. '/' .. rel
        if vim.fn.filereadable(abs) == 1 then
            table.insert(files, abs)
        end
    end
    if #files == 0 then
        vim.api.nvim_echo({ { 'No files changed vs ' .. require('nvim-git-flow.base').label(base) } }, false, {})
        return files
    end
    local escaped = vim.tbl_map(vim.fn.fnameescape, files)
    local ok, e = pcall(vim.cmd, 'args ' .. table.concat(escaped, ' '))
    if not ok then
        err(tostring(e))
    end
    return files
end

return M
