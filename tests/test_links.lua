local h = require('helpers')
local links = require('nvim-git-flow.links')

local T = {}

local function repo_with(remote)
    local dir = h.repo({ 'sample.py' })
    vim.fn.mkdir(dir .. '/pkg', 'p')
    vim.fn.writefile(vim.fn.readfile(h.fixtures .. '/sample.py'), dir .. '/pkg/my mod.py')
    h.sh(dir, { 'add', '.' })
    h.sh(dir, { 'commit', '-q', '-m', 'pkg' })
    h.sh(dir, { 'remote', 'add', 'origin', remote })
    return dir
end

local function head(dir)
    return vim.trim(h.sh(dir, { 'rev-parse', 'HEAD' }))
end

function T.test_https_rewrites()
    h.eq(links.https('git@github.com:o/r.git'), 'https://github.com/o/r')
    h.eq(links.https('ssh://git@gitlab.com/o/r.git'), 'https://gitlab.com/o/r')
    h.eq(links.https('git+ssh://git@example.com/o/r/'), 'https://example.com/o/r')
    h.eq(links.https('https://bitbucket.org/o/r.git'), 'https://bitbucket.org/o/r')
end

function T.test_github_file_and_line()
    local dir = repo_with('git@github.com:o/r.git')
    h.eq(links.remote_url(dir .. '/sample.py'), 'https://github.com/o/r/blob/main/sample.py')
    h.eq(links.remote_url(dir .. '/sample.py', { line = 5 }), 'https://github.com/o/r/blob/main/sample.py#L5')
    h.eq(links.remote_url(dir .. '/sample.py', { line = 3, line_end = 7 }),
        'https://github.com/o/r/blob/main/sample.py#L3-L7')
    h.eq(links.remote_url(dir .. '/pkg/my mod.py'), 'https://github.com/o/r/blob/main/pkg/my%20mod.py')
end

function T.test_github_dir_and_root_tree()
    local dir = repo_with('git@github.com:o/r.git')
    h.eq(links.remote_url(dir .. '/pkg', { kind = 'tree' }), 'https://github.com/o/r/tree/main/pkg')
    h.eq(links.remote_url(dir, { kind = 'tree' }), 'https://github.com/o/r/tree/main')
end

function T.test_gitlab()
    local dir = repo_with('ssh://git@gitlab.com/o/r.git')
    h.eq(links.remote_url(dir .. '/sample.py'), 'https://gitlab.com/o/r/-/blob/main/sample.py')
    h.eq(links.remote_url(dir .. '/sample.py', { line = 5 }), 'https://gitlab.com/o/r/-/blob/main/sample.py#L5')
    h.eq(links.remote_url(dir, { kind = 'tree' }), 'https://gitlab.com/o/r/-/tree/main')
end

function T.test_bitbucket()
    local dir = repo_with('https://bitbucket.org/o/r.git')
    h.eq(links.remote_url(dir .. '/sample.py'), 'https://bitbucket.org/o/r/src/main/sample.py')
    h.eq(links.remote_url(dir .. '/sample.py', { line = 5 }), 'https://bitbucket.org/o/r/src/main/sample.py#L5')
    h.eq(links.remote_url(dir, { kind = 'tree' }), 'https://bitbucket.org/o/r/src/main')
end

function T.test_branch_name()
    local dir = repo_with('git@github.com:o/r.git')
    h.sh(dir, { 'checkout', '-q', '-b', 'feature/x' })
    h.eq(links.remote_url(dir .. '/sample.py'), 'https://github.com/o/r/blob/feature/x/sample.py')
end

function T.test_detached_head_uses_commit()
    local dir = repo_with('git@github.com:o/r.git')
    local sha = head(dir)
    h.sh(dir, { 'checkout', '-q', '--detach' })
    h.eq(links.remote_url(dir .. '/sample.py', { line = 2 }), 'https://github.com/o/r/blob/' .. sha .. '/sample.py#L2')
end

function T.test_errors()
    local dir = h.repo({ 'sample.py' })
    local url, reason = links.remote_url(dir .. '/sample.py')
    h.eq(url, nil)
    h.eq(reason, 'No Git remote found')
    local outside = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(outside, 'p')
    url, reason = links.remote_url(outside)
    h.eq(url, nil)
    h.eq(reason, 'Current file is not in a Git repository')
    url, reason = links.remote_url(nil)
    h.eq(reason, 'Current buffer is not a file')
end

function T.test_copy_cursor_line_and_range()
    local dir = repo_with('git@github.com:o/r.git')
    h.open(dir .. '/sample.py')
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    h.eq(links.copy(true), 'https://github.com/o/r/blob/main/sample.py#L9')
    h.eq(links.copy(false), 'https://github.com/o/r/blob/main/sample.py')
    h.eq(links.copy(true, 7, 3), 'https://github.com/o/r/blob/main/sample.py#L3-L7')
end

function T.test_copy_symlink_uses_real_repo()
    local dir = repo_with('git@github.com:o/r.git')
    local link_dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(link_dir, 'p')
    vim.uv.fs_symlink(dir .. '/sample.py', link_dir .. '/linked.py')
    h.open(link_dir .. '/linked.py')
    h.eq(links.copy(false), 'https://github.com/o/r/blob/main/sample.py')
end

function T.test_open_empty_buffer_opens_repo_root()
    local dir = repo_with('git@github.com:o/r.git')
    vim.cmd('silent! %bwipeout!')
    vim.cmd('cd ' .. vim.fn.fnameescape(dir .. '/pkg'))
    local browser = links.browser
    links.browser = function() return nil end  -- echo instead of launching a browser
    local ok, url = pcall(links.open)
    links.browser = browser
    vim.cmd('cd -')
    assert(ok, url)
    h.eq(url, 'https://github.com/o/r/tree/main')
end

function T.test_open_changed_uses_base()
    local dir = repo_with('git@github.com:o/r.git')
    vim.g.git_diff_base = head(dir)
    h.sh(dir, { 'mv', 'sample.py', 'moved.py' })
    h.sh(dir, { 'commit', '-q', '-m', 'move' })
    vim.fn.writefile({ 'changed' }, dir .. '/pkg/my mod.py')
    h.open(dir .. '/moved.py')
    local files = links.open_changed()
    vim.g.git_diff_base = nil
    table.sort(files)
    h.eq(files, { dir .. '/moved.py', dir .. '/pkg/my mod.py' })
    h.eq(vim.fn.argc(), 2)
    vim.cmd('%argdelete')
end

return T
