if vim.g.loaded_nvim_git_flow then
    return
end
vim.g.loaded_nvim_git_flow = true

-- plugin/ files load after the user's config; keep an explicit setup() the config already ran
local flow = require('nvim-git-flow')
if not flow._configured then
    flow.setup()
end

local function cmd(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, opts or {})
end

local function ref_complete(arglead)
    return require('nvim-git-flow.base').complete(arglead)
end

-- diff base
cmd('ChangeGitDiffBase', function(a)
    require('nvim-git-flow.base').set(a.args)
end, { nargs = '?', complete = ref_complete, desc = 'Set the ref git views diff against' })

-- signs and hunks
cmd('GitHunkNext', function() require('nvim-git-flow.signs').next_hunk() end, { desc = 'Jump to the next hunk' })
cmd('GitHunkPrev', function() require('nvim-git-flow.signs').prev_hunk() end, { desc = 'Jump to the previous hunk' })
cmd('GitHunkPreview', function() require('nvim-git-flow.signs').preview_hunk() end, { desc = 'Preview the hunk under the cursor' })
cmd('GitHunkStage', function() require('nvim-git-flow.signs').stage_hunk() end, { desc = 'git add the hunk under the cursor' })
cmd('GitHunkUndo', function() require('nvim-git-flow.signs').undo_hunk() end, { desc = 'Revert the hunk under the cursor to the base' })
cmd('GitHunkFold', function() require('nvim-git-flow.signs').toggle_fold() end, { desc = 'Fold everything but the hunks (toggle)' })
cmd('GitSignsToggle', function() require('nvim-git-flow.signs').toggle() end, { desc = 'Turn git signs on/off' })
cmd('GitHunks', function() require('nvim-git-flow.signs').to_loclist() end, { desc = 'List hunks in the location list' })

-- side-by-side diff tab
cmd('DiffSplit', function(a)
    require('nvim-git-flow.diffsplit').open(a.args)
end, { nargs = '?', complete = ref_complete, desc = 'Diff this buffer against a git ref, in a new tab' })

-- blame
cmd('GitBlameToggle', function() require('nvim-git-flow.blame').toggle() end, { desc = 'Toggle blame of the cursor line' })

-- remote links
cmd('GitOpen', function() require('nvim-git-flow.links').open() end, { desc = 'Open this file (or repo) on the remote' })
cmd('OpenGithubLink', function() require('nvim-git-flow.links').open() end, { desc = 'Alias of :GitOpen' })
cmd('GithubLink', function() require('nvim-git-flow.links').copy(false) end, { desc = "Copy this file's remote URL" })
-- with a range (:'<,'>GithubLinkCurrentLine) the URL covers those lines, e.g. #L3-L7
local function copy_lines(a)
    require('nvim-git-flow.links').copy(true, a.range > 0 and a.line1 or nil, a.range > 0 and a.line2 or nil)
end
cmd('GithubLinkCurrentLine', copy_lines, { range = true, desc = "Copy this line's (or range's) remote URL" })
cmd('RemoteGitFileReference', copy_lines, { range = true, desc = 'Alias of :GithubLinkCurrentLine' })
cmd('OpenChangedFiles', function() require('nvim-git-flow.links').open_changed() end, { desc = 'Open every file changed vs the base' })
