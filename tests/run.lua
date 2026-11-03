-- Runs every test in tests/test_*.lua: nvim --clean -l tests/run.lua
-- Each test file returns a table of flat test functions; a test fails by raising an error.
local tests_dir = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ':p')))
vim.opt.rtp:prepend(vim.fs.dirname(tests_dir))
package.path = tests_dir .. '/?.lua;' .. package.path
local failed = 0
local only = arg[1]
local files = vim.fn.glob(tests_dir .. '/test_*.lua', false, true)
table.sort(files)
for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ':t:r')
    if not only or name == only then
        local tests = require(name)
        local names = vim.tbl_keys(tests)
        table.sort(names)
        for _, fn in ipairs(names) do
            local ok, err = pcall(tests[fn])
            print(string.format('%s %s.%s%s', ok and 'PASS' or 'FAIL', name, fn, ok and '' or ('\n    ' .. tostring(err))))
            if not ok then failed = failed + 1 end
        end
    end
end
os.exit(failed == 0 and 0 or 1)
