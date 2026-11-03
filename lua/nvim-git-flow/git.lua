-- Small synchronous git helpers shared by every module. Paths are resolved first, so a file
-- opened through a symlink (e.g. tmp/workfiles -> another repo) is looked up in the repo it
-- really lives in.

local M = {}

-- Run git in `dir`. Returns stdout (string), exit code, stderr.
function M.run(dir, args, stdin)
    local cmd = vim.list_extend({ 'git', '-C', dir }, args)
    local res = vim.system(cmd, { text = true, stdin = stdin }):wait()
    return res.stdout or '', res.code, res.stderr or ''
end

-- Real path of a buffer's file, or nil for a buffer that isn't a file.
function M.buf_path(buf)
    buf = buf or 0
    if vim.bo[buf].buftype ~= '' then
        return nil
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if name == '' then
        return nil
    end
    return vim.fn.resolve(vim.fn.fnamemodify(name, ':p'))
end

-- Top folder of the repo holding `path` (a file or dir), or nil outside git.
function M.root(path)
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    local out, code = M.run(dir, { 'rev-parse', '--show-toplevel' })
    if code ~= 0 then
        return nil
    end
    return vim.trim(out)
end

-- Path of `path` relative to its repo root as git names it, or nil when git doesn't track it.
function M.tracked(path)
    local out, code = M.run(vim.fs.dirname(path), { 'ls-files', '--full-name', '--', path })
    out = vim.trim(out)
    if code ~= 0 or out == '' then
        return nil
    end
    return out
end

-- Lines of `path` at `ref`. Returns lines, nil when found; nil, reason when git doesn't have it
-- there (outside a repo, untracked, or not in that ref).
function M.show(path, ref)
    local rel = M.tracked(path)
    if not rel then
        return nil, 'untracked'
    end
    local out, code, err = M.run(vim.fs.dirname(path), { 'show', ref .. ':' .. rel })
    if code ~= 0 then
        return nil, vim.trim(err)
    end
    local lines = vim.split(out, '\n', { plain = true })
    if lines[#lines] == '' then
        table.remove(lines)
    end
    return lines
end

-- Full commit id for `ref`, or nil.
function M.rev_parse(dir, ref)
    local out, code = M.run(dir, { 'rev-parse', '--verify', '--quiet', ref })
    if code ~= 0 then
        return nil
    end
    return vim.trim(out)
end

return M
