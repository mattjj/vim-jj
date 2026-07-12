# vim-jj

A small Vim plugin for the [Jujutsu](https://github.com/jj-vcs/jj) version
control system (`jj`), in the spirit of tpope's
[fugitive.vim](https://github.com/tpope/vim-fugitive).

It deliberately covers a *narrow* slice of fugitive's surface — blame,
diff, and object browsing — rather than trying to be a full port.

A design goal is that everything works in **any jj workspace**, including
secondary workspaces created with `jj workspace add`, where there is no
`.git` directory anywhere above your files. Workspace discovery only ever
looks for a `.jj` directory, and every `jj` invocation passes an explicit
`--repository` flag, so Vim's current directory never matters either.

## Commands

fugitive | vim-jj | what it does
--- | --- | ---
`:Git blame` | `:J blame` | annotations for the current file in a scroll-bound left split (`q` to close, `<CR>` to open the commit that introduced a line, `o` for a split)
`:Git diff` | `:J diff [args]` | `jj diff --git` output in a scratch window with diff highlighting (`:J diff -r @-`, `:J diff --stat`, ...)
`:Gdiffsplit` | `:J diffsplit [revset]` | vimdiff the current file against the same file at `revset` (default: the parent of the buffer's revision, i.e. `@-` for a working-copy file)
`:Gedit` | `:J edit {object}` | open a read-only buffer for a jj object: `:J edit @-` (a commit, like `jj show`), `:J edit @-:src/main.rs` (a file at a revision), `:J edit @-:%` (the current file at a revision)
`:Gsplit` etc. | `:J split` / `:J vsplit` / `:J tabedit` / `:J pedit` | same, in a split/tab/preview window
`:Git <anything>` | `:J <anything>` | any other subcommand is passed through to jj and its output shown in a scratch window: `:J`, (= `jj status`), `:J log`, `:J new`, `:J describe -m msg`, `:J op log`, ...

Like fugitive, blame/diffsplit/edit compose: from a buffer showing a file
at an old revision, `:J blame` annotates as of that revision, `:J
diffsplit` diffs against that revision's parent, and `:J edit` (no
argument) takes you back to the working copy.

`:JJ` is an alias for `:J` in case another plugin owns `:J`.

## Installation

Any plugin manager works, e.g. with vim-plug:

```vim
Plug 'mattjj/vim-jj'
```

or with Vim 8 packages:

```sh
git clone https://github.com/mattjj/vim-jj \
  ~/.vim/pack/plugins/start/vim-jj
```

Requires Vim 8.2+ (or Neovim) and a reasonably recent `jj` (`:J blame`
uses `jj file annotate -T`; tested with jj 0.43).

## Configuration

```vim
let g:jj_executable = 'jj'      " name/path of the jj binary
let g:jj_blame_template = '...' " jj template for blame annotation lines
```

## Caveats

- Commands that want to spawn an editor will fail; pass `-m` style flags
  instead (`:J describe -m message`).
- `:J blame` requires the buffer to be written first (jj snapshots the
  working copy when it runs, so the file on disk is what gets annotated).
- No `:Gwrite`/staging analogue — jj doesn't have an index, so a good
  chunk of fugitive has no jj counterpart anyway.

## Credit

The interface and much of the implementation approach (object buffers
populated by a `BufReadCmd`, the scroll-bound blame window) are borrowed
with gratitude from [fugitive.vim](https://github.com/tpope/vim-fugitive).
