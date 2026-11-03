# nvim-git-flow

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-blue.svg)](https://neovim.io/)

Git in the editor, all against one shared diff base: signs for changed lines, hunk preview, stage
and undo, a side-by-side diff tab, cursor-line blame, and links to the file on GitHub, GitLab or
Bitbucket.

## Features

- **Signs**: a bar in the sign column (and a colored line number) for added, changed and deleted
  lines, updated as you type. Unsaved edits count. No signs outside git or in ignored files.
- **Hunks**: jump to the next/previous one, preview it in a float, stage it (`git apply --cached`),
  undo it back to the base, fold everything else away, or list them all in the location list.
- **Diff tab** (`:DiffSplit [ref]`): the file at a ref on the left, your buffer on the right, in a
  new tab so your layout is untouched. `q` in either window closes it. Files git doesn't track are
  compared with the saved file.
- **Blame** (`:GitBlameToggle`): author, age and summary of the cursor line's commit as virtual text.
- **Remote links**: open the file, or copy a link to it or to the selected lines.
- **One diff base** (`:ChangeGitDiffBase [ref]`): signs and the diff tab compare against
  `g:git_diff_base`, and the name it was picked by (the ref you typed, or `main`/`master` for
  the fork point) in `g:git_diff_base_name`. Other plugins can read them and listen for
  `User GitDiffBaseChanged`.

## Install

[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'solomonxie/nvim-git-flow'
```

It works with no setup. To change options or add keys:

```lua
require('nvim-git-flow').setup({
    base = 'HEAD',  -- '' = where the current branch forked from main/master
    keymaps = {
        hunk_next = ']h',
        hunk_prev = '[h',
        hunk_preview = '<Leader>hp',
        hunk_stage = '<Leader>hs',
        hunk_undo = '<Leader>hu',
        hunk_fold = false,     -- e.g. 'gz'
        diff_split = false,    -- e.g. 'gD'
        blame_toggle = false,  -- e.g. 'tb'
    },
})
```

Every option and its default is in [lua/nvim-git-flow/config.lua](lua/nvim-git-flow/config.lua).

## Commands

| Command | What it does |
|---|---|
| `:ChangeGitDiffBase [ref]` | Diff against `ref`; no ref = the branch's fork point from main/master |
| `:DiffSplit [ref]` | Side-by-side diff tab against `ref` (default: the diff base) |
| `:GitHunkNext` / `:GitHunkPrev` | Jump to the next / previous hunk |
| `:GitHunkPreview` | Show the hunk under the cursor in a float |
| `:GitHunkStage` / `:GitHunkUndo` | Stage the hunk / revert it to the base |
| `:GitHunkFold` | Fold all but the hunks (toggle) |
| `:GitHunks` | Hunks in the location list |
| `:GitSignsToggle` | Turn signs on/off |
| `:GitBlameToggle` | Blame of the cursor line |
| `:GitOpen` | Open the file (or repo) on the remote |
| `:GithubLink` / `:[range]GithubLinkCurrentLine` | Copy the file's / line's URL |
| `:OpenChangedFiles` | Open every file changed against the base |

## Highlights

`GitFlowAdd`, `GitFlowChange`, `GitFlowDelete`, `GitFlowChangeDelete` (signs), `GitFlowAddNr`,
`GitFlowChangeNr`, `GitFlowDeleteNr` (line numbers), `GitFlowAddLine`, `GitFlowChangeLine` (line
tint when `signs.linehl` is on). They're defined as defaults, so your own colors win.

## Tests

```
nvim --clean -l tests/run.lua            # every test
nvim --clean -l tests/run.lua test_signs # one file
```
