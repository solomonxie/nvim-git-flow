-- Shared test helpers: a throwaway git repo built from the committed fixture files.
local M = {}

M.fixtures = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))) .. '/fixtures'

function M.eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected),
        string.format('%s: expected %s, got %s', msg or 'eq', vim.inspect(expected), vim.inspect(actual)))
end

local function sh(dir, args)
    local res = vim.system(vim.list_extend({ 'git', '-C', dir }, args), { text = true }):wait()
    assert(res.code == 0, table.concat(args, ' ') .. ': ' .. (res.stderr or ''))
    return res.stdout
end
M.sh = sh

-- A new repo in a temp dir with fixtures/<name> committed as <name>. Returns the repo dir.
function M.repo(names)
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, 'p')
    sh(dir, { 'init', '-q', '-b', 'main' })
    sh(dir, { 'config', 'user.name', 'Test' })
    sh(dir, { 'config', 'user.email', 'test@example.com' })
    sh(dir, { 'config', 'commit.gpgsign', 'false' })
    for _, name in ipairs(names) do
        vim.fn.writefile(vim.fn.readfile(M.fixtures .. '/' .. name), dir .. '/' .. name)
    end
    sh(dir, { 'add', '.' })
    sh(dir, { 'commit', '-q', '-m', 'fixtures' })
    return dir
end

-- Open `path` in a fresh buffer of the current window and return its number.
function M.open(path)
    vim.cmd('silent! %bwipeout!')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
end

return M
