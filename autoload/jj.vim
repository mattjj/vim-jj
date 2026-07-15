" autoload/jj.vim - Jujutsu (jj) support for Vim, in the spirit of fugitive.vim
" Works in any jj workspace, including secondary workspaces created with
" `jj workspace add` (no .git directory anywhere in the lineage): the only
" thing we ever look for is a .jj directory, and every jj invocation gets an
" explicit --repository flag so Vim's cwd never matters.

if exists('g:autoloaded_jj')
  finish
endif
let g:autoloaded_jj = 1

" Section: utility

function! s:throw(string) abort
  throw 'jj: ' . a:string
endfunction

function! s:Executable() abort
  return get(g:, 'jj_executable', 'jj')
endfunction

" Split a command line into arguments, honoring backslash-escaped spaces
" (same convention as fugitive: `:J describe -m hello\ world`).
function! s:ArgSplit(string) abort
  let string = a:string
  let args = []
  while string =~# '\S'
    let arg = matchstr(string, '^\s*\zs\%(\\.\|\S\)\+')
    let string = strpart(string, matchend(string, '^\s*\%(\\.\|\S\)\+'))
    call add(args, substitute(arg, '\\\(\s\)', '\1', 'g'))
  endwhile
  return args
endfunction

" Section: repository detection

function! s:FindRoot(path) abort
  let dir = fnamemodify(a:path, ':p')
  if !isdirectory(dir)
    let dir = fnamemodify(dir, ':h')
  endif
  let dir = substitute(dir, '/\+$', '', '')
  while 1
    if isdirectory(dir . '/.jj')
      return dir
    endif
    let parent = fnamemodify(dir, ':h')
    if parent ==# dir
      return ''
    endif
    let dir = parent
  endwhile
endfunction

" Workspace root for the current buffer (or for an explicit path argument).
" Returns '' if not in a jj workspace.
function! jj#Root(...) abort
  if a:0
    return s:FindRoot(a:1)
  endif
  if !empty(get(b:, 'jj_root', '')) && isdirectory(b:jj_root . '/.jj')
    return b:jj_root
  endif
  let name = bufname('%')
  if name =~# '^jj://'
    let root = s:ParseUrl(name)[0]
  elseif !empty(name) && &buftype !~# '^\%(nofile\|acwrite\|quickfix\|terminal\|prompt\|popup\)$'
    let root = s:FindRoot(expand('%:p'))
  else
    let root = s:FindRoot(getcwd())
  endif
  if !empty(root)
    let b:jj_root = root
  endif
  return root
endfunction

function! s:Root() abort
  let root = jj#Root()
  if empty(root)
    call s:throw('not inside a jj workspace (no .jj directory found)')
  endif
  return root
endfunction

" Section: running jj

function! s:Argv(root, args, ignore_wc, color) abort
  let argv = [s:Executable(), '--repository', a:root, '--no-pager',
        \ '--color', a:color ? 'always' : 'never']
  if a:ignore_wc
    call add(argv, '--ignore-working-copy')
  endif
  return argv + a:args
endfunction

" Run jj with stdout and stderr merged; returns [lines, exit_status].
function! s:JJ(root, args, ...) abort
  let argv = s:Argv(a:root, a:args, a:0 && a:1, a:0 > 1 && a:2)
  let cmd = join(map(copy(argv), 'shellescape(v:val)'), ' ') . ' 2>&1'
  let lines = systemlist(cmd)
  return [lines, v:shell_error]
endfunction

" Run jj keeping stdout pristine (for file contents); stderr is captured
" separately and returned as the error message on failure.
function! s:JJContent(root, args, ...) abort
  let argv = s:Argv(a:root, a:args, a:0 && a:1, 0)
  let errfile = tempname()
  let cmd = join(map(copy(argv), 'shellescape(v:val)'), ' ') . ' 2>' . shellescape(errfile)
  let lines = systemlist(cmd)
  let status = v:shell_error
  if status
    let lines = filter(readfile(errfile), '!empty(v:val)')
  endif
  call delete(errfile)
  return [lines, status]
endfunction

" Resolve a revset to exactly one full commit id.
function! s:ResolveRev(root, revset) abort
  let [out, status] = s:JJ(a:root, ['log', '--no-graph', '-n', '2',
        \ '-r', a:revset, '-T', 'commit_id ++ "\n"'])
  if status
    call s:throw(join(out, ' '))
  endif
  call filter(out, 'v:val =~# ''^\x\+$''')
  if empty(out)
    call s:throw('revset resolved to no commits: ' . a:revset)
  elseif len(out) > 1
    call s:throw('revset resolved to multiple commits: ' . a:revset)
  endif
  return out[0]
endfunction

" Section: jj:// object URLs
"
" Files at a revision:  jj://<workspace root>//<commit id>/<repo-relative path>
" Commits (jj show):    jj://<workspace root>//<commit id>
" Revsets are resolved to full commit ids *before* the URL is built, so the
" URL grammar stays unambiguous no matter what characters a revset contains.

function! s:ParseUrl(url) abort
  let m = matchlist(a:url, '^jj://\(.\{-}\)//\(\x\+\)\%(/\(.*\)\)\=$')
  if empty(m)
    return ['', '', '']
  endif
  return [m[1], m[2], m[3]]
endfunction

function! s:Url(root, cid, path) abort
  return 'jj://' . a:root . '//' . a:cid . (empty(a:path) ? '' : '/' . a:path)
endfunction

" Escape a repo-relative path for use in a jj fileset expression.
function! s:Fileset(path) abort
  let path = substitute(a:path, '\\', '\\\\', 'g')
  let path = substitute(path, '"', '\\"', 'g')
  return 'root:"' . path . '"'
endfunction

" Repo-relative path of the current buffer within root.
function! s:BufPath(root) abort
  let name = bufname('%')
  if name =~# '^jj://'
    let [root, _, path] = s:ParseUrl(name)
    if root !=# a:root
      call s:throw('buffer belongs to a different workspace: ' . root)
    endif
    if empty(path)
      call s:throw('not a file buffer')
    endif
    return path
  endif
  let name = fnamemodify(name, ':p')
  let prefix = a:root . '/'
  if strpart(name, 0, len(prefix)) ==# prefix
    return strpart(name, len(prefix))
  endif
  call s:throw('file is not inside the jj workspace: ' . name)
endfunction

" Commit id backing the current buffer: for jj:// buffers, the commit in the
" URL; for regular files, the working-copy commit @.
function! s:BufRev(root) abort
  let name = bufname('%')
  if name =~# '^jj://'
    return s:ParseUrl(name)[1]
  endif
  return '@'
endfunction

function! jj#BufReadCmd(amatch) abort
  let [root, cid, path] = s:ParseUrl(a:amatch)
  if empty(root)
    return 'echoerr "jj: invalid jj:// URL"'
  endif
  let b:jj_root = root
  try
    if empty(path)
      let [lines, status] = s:JJContent(root, ['show', '--git', '-r', cid], 1)
    else
      let [lines, status] = s:JJContent(root, ['file', 'show', '-r', cid, '--', s:Fileset(path)], 1)
    endif
    setlocal noswapfile buftype=nowrite
    setlocal modifiable noreadonly
    let ul = &l:undolevels
    setlocal undolevels=-1
    silent keepjumps %delete _
    if !empty(lines)
      call setline(1, lines)
    endif
    let &l:undolevels = ul
    setlocal nomodified nomodifiable readonly
    if status
      return 'echoerr ' . string('jj: ' . join(lines, ' '))
    endif
    if empty(path)
      setlocal filetype=jjshow
      call s:MapHunkNav()
    else
      exe 'doautocmd filetypedetect BufRead ' . fnameescape(root . '/' . path)
    endif
    return ''
  catch /^jj:/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

" Section: :J edit / split / vsplit / tabedit / pedit

" Interpret an object argument:
"   ''            -> from a jj:// file buffer, the working-copy file;
"                    otherwise an error
"   <revset>      -> the current file as of <revset>; from a buffer with
"                    no file (an output window, a commit view), the
"                    commit itself instead
"   <revset>:<path> -> the file <path> (repo-relative) at <revset>
"   <revset>:     -> the current file at <revset>
"   :<path>       -> <path> in the working-copy commit @
" A whole-argument revset wins over the rev:path split, so revsets that
" contain colons (e.g. ::main) still work unquoted.
function! s:ParseObject(root, arg) abort
  let arg = a:arg
  if arg =~# ':'
    try
      return [s:ResolveRev(a:root, arg), s:BufPathMaybe(a:root)]
    catch /^jj:.*multiple commits/
      " A valid revset, just not a singleton: report that rather than
      " misparsing it as rev:path.
      throw v:exception
    catch /^jj:/
    endtry
    let rev = matchstr(arg, '^[^:]*')
    let path = matchstr(arg, ':\zs.*')
    if empty(rev)
      let rev = '@'
    endif
    if empty(path) || path ==# '%'
      let path = s:BufPath(a:root)
    endif
    return [s:ResolveRev(a:root, rev), path]
  endif
  return [s:ResolveRev(a:root, arg), s:BufPathMaybe(a:root)]
endfunction

" The current buffer's repo-relative path, or '' when the buffer has no
" file in the workspace (output windows, commit views, unnamed buffers).
function! s:BufPathMaybe(root) abort
  try
    return s:BufPath(a:root)
  catch /^jj:/
    return ''
  endtry
endfunction

function! s:EditCommand(cmd, mods, arg) abort
  let root = s:Root()
  if empty(a:arg)
    let name = bufname('%')
    if name =~# '^jj://'
      let [r, cid, path] = s:ParseUrl(name)
      if empty(path)
        call s:throw('no file associated with this commit buffer')
      endif
      exe s:Mods(a:mods) . a:cmd . ' ' . fnameescape(r . '/' . path)
      return ''
    endif
    call s:throw('nothing to do: already editing the working copy')
  endif
  let [cid, path] = s:ParseObject(root, a:arg)
  exe s:Mods(a:mods) . a:cmd . ' ' . fnameescape(s:Url(root, cid, path))
  return ''
endfunction

function! s:Mods(mods) abort
  let mods = substitute(a:mods, '\C<mods>', '', '')
  return empty(mods) ? '' : mods . ' '
endfunction

" Section: :J diffsplit

function! s:DiffSplit(mods, arg, bang) abort
  if a:bang
    return s:MergeSplit(a:mods)
  endif
  let root = s:Root()
  let path = s:BufPath(root)
  if empty(a:arg)
    let rev = s:BufRev(root) . '-'
  else
    let rev = a:arg
  endif
  try
    let cid = s:ResolveRev(root, rev)
  catch /^jj:.*multiple commits/
    if empty(a:arg)
      call s:throw('revision has multiple parents; use :J diffsplit! for a '
            \ . 'three-pane merge view, or pass an explicit revset')
    endif
    throw v:exception
  endtry
  " Validate up front so we don't enter diff mode against an error buffer.
  let [lines, status] = s:JJContent(root, ['file', 'show', '-r', cid, '--', s:Fileset(path)], 1)
  if status
    call s:throw(join(lines, ' '))
  endif
  let url = s:Url(root, cid, path)
  diffthis
  let origin = win_getid()
  let mods = empty(s:Mods(a:mods)) ? 'keepalt leftabove vertical ' : 'keepalt ' . s:Mods(a:mods)
  exe mods . 'split ' . fnameescape(url)
  diffthis
  let b:jj_diff_origin = origin
  augroup jj_diff
    exe 'autocmd! BufWinLeave <buffer=' . bufnr('') . '> ++once call s:DiffRestore(getbufvar(str2nr(expand("<abuf>")), "jj_diff_origin", 0))'
  augroup END
  call win_gotoid(origin)
  return ''
endfunction

function! s:DiffRestore(origin) abort
  if a:origin && win_id2win(a:origin) && getwinvar(win_id2win(a:origin), '&diff')
    call win_execute(a:origin, 'diffoff')
  endif
endfunction

" Section: :J diffsplit! (three-pane merge view)

" Parse a git-marker-style materialized conflict into full texts for each
" side.  Non-conflict lines are shared by side1, base, and side2; each
" conflict region contributes its own lines to the respective text.
function! s:ParseGitMarkers(lines) abort
  let out = {'conflicted': 0, 'multiway': 0, 'side1': [], 'base': [],
        \ 'side2': [], 'label1': '', 'label2': ''}
  let state = 0
  for line in a:lines
    if state == 0
      if line =~# '^<\{7,}\%( \|$\)'
        let state = 1
        let out.conflicted = 1
        if empty(out.label1)
          let out.label1 = matchstr(line, '^<\{7,} \zs.*')
        endif
      else
        call add(out.side1, line)
        call add(out.base, line)
        call add(out.side2, line)
      endif
    elseif state == 1
      if line =~# '^|\{7,}\%( \|$\)'
        let state = 2
      elseif line =~# '^%\{7,}\|^+\{7,}'
        " jj emits its default diff-style markers instead of git-style ones
        " when a conflict has more than two sides
        let out.multiway = 1
        return out
      else
        call add(out.side1, line)
      endif
    elseif state == 2
      if line =~# '^=\{7,}$'
        let state = 3
      else
        call add(out.base, line)
      endif
    elseif state == 3
      if line =~# '^>\{7,}\%( \|$\)'
        let state = 0
        if empty(out.label2)
          let out.label2 = matchstr(line, '^>\{7,} \zs.*')
        endif
      else
        call add(out.side2, line)
      endif
    endif
  endfor
  return out
endfunction

" Like fugitive's :Gdiffsplit! on a conflicted file: side 1 on the left,
" the working file (with conflict markers) in the middle, side 2 on the
" right, all in diff mode.  d2o/d3o in the middle pull a hunk from the
" left/right; dp in a side pane pushes its hunk to the middle.  Resolve by
" editing the middle buffer and writing it: jj snapshots the working copy
" on its next invocation and considers marker-free files resolved.
function! s:MergeSplit(mods) abort
  let root = s:Root()
  let path = s:BufPath(root)
  let rev = s:BufRev(root)
  " Wipe panes left over from a previous merge view of this buffer.
  let middlenr = bufnr('')
  for buf in range(1, bufnr('$'))
    if bufexists(buf) && getbufvar(buf, 'jj_merge_origin', -1) == middlenr
      exe 'silent! bwipeout! ' . buf
    endif
  endfor
  " Materialize with git-style markers so the sides can be reconstructed.
  " No --ignore-working-copy when rev is @: the snapshot makes jj re-parse
  " any partial resolution already sitting in the file on disk.
  let [lines, status] = s:JJContent(root, ['file', 'show', '-r', rev,
        \ '--config', 'ui.conflict-marker-style=git', '--', s:Fileset(path)],
        \ rev !=# '@')
  if status
    call s:throw(join(lines, ' '))
  endif
  let conflict = s:ParseGitMarkers(lines)
  if !conflict.conflicted
    call s:throw('no conflict in ' . path . ' at ' . rev)
  endif
  if conflict.multiway
    call s:throw('conflict has more than two sides; use jj resolve, or '
          \ . 'edit the conflict markers directly')
  endif

  let middle = win_getid()
  diffthis
  let side1nr = s:MergePane(root, path, 'leftabove', 1, conflict.side1)
  let side2nr = s:MergePane(root, path, 'rightbelow', 2, conflict.side2)
  exe 'nnoremap <buffer> <silent> d2o :diffget ' . side1nr . '<Bar>diffupdate<CR>'
  exe 'nnoremap <buffer> <silent> d3o :diffget ' . side2nr . '<Bar>diffupdate<CR>'
  " Wire up cleanup: when the last side pane goes away, take the middle
  " window out of diff mode.
  augroup jj_merge
    exe 'autocmd! BufWinLeave <buffer=' . side1nr . '> ++once '
          \ . 'call s:MergePaneClosed(' . middle . ', ' . side2nr . ')'
    exe 'autocmd! BufWinLeave <buffer=' . side2nr . '> ++once '
          \ . 'call s:MergePaneClosed(' . middle . ', ' . side1nr . ')'
  augroup END
  echo 'side #1 (d2o): ' . conflict.label1 . ' | side #2 (d3o): ' . conflict.label2
  return ''
endfunction

" Create one read-only side pane and return its buffer number; leaves the
" middle window focused.
function! s:MergePane(root, path, where, side, lines) abort
  let middle = win_getid()
  let middlenr = bufnr('')
  exe 'silent keepalt ' . a:where . ' vertical new'
  setlocal buftype=nofile bufhidden=wipe noswapfile
  silent! exe 'file ' . fnameescape('jjconflict://' . a:side . '/' . a:path)
  call setline(1, a:lines)
  setlocal nomodified nomodifiable readonly
  exe 'doautocmd filetypedetect BufRead ' . fnameescape(a:root . '/' . a:path)
  let b:jj_root = a:root
  let b:jj_merge_origin = middlenr
  exe 'nnoremap <buffer> <silent> dp :diffput ' . middlenr . '<Bar>diffupdate<CR>'
  nnoremap <buffer> <silent> q :close<CR>
  diffthis
  let nr = bufnr('')
  call win_gotoid(middle)
  return nr
endfunction

function! s:MergePaneClosed(middle, other) abort
  if bufwinnr(a:other) < 0 && win_id2win(a:middle)
    call win_execute(a:middle, 'diffoff')
  endif
endfunction

" Section: :J blame
"
" jj file annotate can take a while on files with deep history, so blame
" is asynchronous by default: the pane opens immediately and fills in when
" jj finishes.  Results are also cached: annotate output is a pure
" function of (commit id, path, template), so @ is resolved to a commit id
" first - which snapshots the working copy, making the cache key track
" file edits automatically - and the annotate job itself then runs with
" --ignore-working-copy.

let s:blame_template =
      \ 'separate(" ",'
      \ . ' commit.change_id().shortest(8),'
      \ . ' pad_end(10, truncate_end(10, commit.author().email().local())),'
      \ . ' commit.author().timestamp().local().format("%Y-%m-%d %H:%M"),'
      \ . ' pad_start(4, line_number)'
      \ . ') ++ "\n"'

let s:annotate_cache = {'order': [], 'data': {}}

function! s:Blame(mods, args) abort
  let root = s:Root()
  " Toggle: if we're already in a blame window, or one exists for this
  " buffer, close it.
  if !empty(get(b:, 'jj_blame', {}))
    close
    return ''
  endif
  for winnr in range(1, winnr('$'))
    let blame = getbufvar(winbufnr(winnr), 'jj_blame', {})
    if get(blame, 'origin', -1) == win_getid()
      exe winnr . 'wincmd c'
      return ''
    endif
  endfor
  if &modified
    call s:throw('buffer is modified; write it first')
  endif
  let path = s:BufPath(root)
  let rev = s:BufRev(root)
  let template = get(g:, 'jj_blame_template', s:blame_template)

  let cachable = empty(a:args)
  if cachable
    let cid = s:ResolveRev(root, rev)
    let key = join([root, cid, path, template], "\n")
    if has_key(s:annotate_cache.data, key)
      call s:BlameOpen(root, path, s:annotate_cache.data[key], 0)
      return ''
    endif
    let lines = s:DiskCacheRead(root, key)
    if !empty(lines)
      " Promote to the in-memory cache (which also refreshes the disk
      " entry's mtime, keeping the pruning LRU-ish).
      call s:BlameCacheStore(root, key, lines)
      call s:BlameOpen(root, path, lines, 0)
      return ''
    endif
    let cmd = ['file', 'annotate', '-r', cid, '-T', template,
          \ '--', root . '/' . path]
    let ignore_wc = 1
  else
    let key = ''
    let cmd = ['file', 'annotate', '-r', rev, '-T', template] + a:args
          \ + ['--', root . '/' . path]
    let ignore_wc = rev !=# '@'
  endif

  if get(g:, 'jj_blame_async', 1) && (exists('*job_start') || exists('*jobstart'))
    let bufnr = s:BlameOpen(root, path, ['annotating...'], 1)
    call s:BlameStartJob(root, s:Argv(root, cmd, ignore_wc, 0), bufnr, key)
  else
    let [lines, status] = s:JJContent(root, cmd, ignore_wc)
    if status
      call s:throw(join(lines, ' '))
    endif
    call s:BlameCacheStore(root, key, lines)
    call s:BlameOpen(root, path, lines, 0)
  endif
  return ''
endfunction

" Create the blame window (fugitive-style scroll-bound left vsplit) and
" fill it; with pending set, it shows a placeholder until the job lands.
function! s:BlameOpen(root, path, lines, pending) abort
  " Configure the origin window like fugitive does, remembering what to
  " restore when the blame window goes away.
  let origin = win_getid()
  let restore = 'setlocal'
        \ . (&l:scrollbind ? '' : ' noscrollbind')
        \ . (&l:wrap ? ' wrap' : '')
        \ . (&l:foldenable ? ' foldenable' : '')
  setlocal scrollbind nowrap nofoldenable

  exe 'silent keepalt leftabove vertical 40 new'
  setlocal buftype=nofile bufhidden=wipe noswapfile nomodified
  silent! exe 'file ' . fnameescape('jj-blame://' . a:path)
  setlocal nowrap nofoldenable nonumber norelativenumber
  setlocal foldcolumn=0 signcolumn=no winfixwidth cursorline
  setlocal filetype=jjblame
  let b:jj_root = a:root
  let b:jj_blame = {'origin': origin, 'restore': restore, 'path': a:path,
        \ 'pending': a:pending}

  nnoremap <buffer> <silent> q :close<CR>
  nnoremap <buffer> <silent> <CR> :call <SID>BlameJump('')<CR>
  nnoremap <buffer> <silent> o :call <SID>BlameJump('split')<CR>
  nnoremap <buffer> <silent> O :call <SID>BlameJump('tabedit')<CR>
  nnoremap <buffer> <silent> gf :call <SID>BlameJump('', 1)<CR>
  augroup jj_blame
    exe 'autocmd! BufWinLeave <buffer=' . bufnr('') . '> ++once call s:BlameRestore(getbufvar(str2nr(expand("<abuf>")), "jj_blame", {}))'
  augroup END
  call s:BlameFillHere(a:lines, a:pending)
  return bufnr('')
endfunction

" Fill the current (blame) window; runs at creation and again when an
" async annotate job completes.
function! s:BlameFillHere(lines, pending) abort
  setlocal modifiable noreadonly
  silent keepjumps %delete _
  call setline(1, a:lines)
  setlocal nomodified nomodifiable readonly
  let b:jj_blame.pending = a:pending
  if a:pending
    return
  endif
  call s:BlameColors(a:lines)
  exe 'vertical resize '
        \ . (max(map(copy(a:lines), 'strdisplaywidth(v:val)')) + 1)
  " Align the viewport with the origin window, then bind scrolling.
  let origin = b:jj_blame.origin
  if win_id2win(origin)
    exe min([line('w0', origin) + getwinvar(origin, '&scrolloff'), line('$')])
    normal! zt
    exe min([line('.', origin), line('$')])
  endif
  setlocal scrollbind
  syncbind
endfunction

function! s:BlameCacheStore(root, key, lines) abort
  if empty(a:key)
    return
  endif
  if !has_key(s:annotate_cache.data, a:key)
    call add(s:annotate_cache.order, a:key)
    if len(s:annotate_cache.order) > 20
      call remove(s:annotate_cache.data, remove(s:annotate_cache.order, 0))
    endif
  endif
  let s:annotate_cache.data[a:key] = a:lines
  call s:DiskCacheWrite(a:root, a:key, a:lines)
endfunction

" Disk cache: annotations are keyed by (root, commit id, path, template)
" and commits are immutable, so entries can never go stale and survive
" across Vim sessions (and are shared between concurrent Vim instances).
" Lives inside the workspace's .jj directory by default - per-repo and
" never tracked, no .gitignore required, the same way fugitive keeps its
" state under .git.  g:jj_cache_dir overrides with a single shared
" directory; set it to '' to disable the disk cache.
function! s:DiskCacheFile(root, key) abort
  if !exists('*sha256') || empty(a:key)
    return ''
  endif
  if exists('g:jj_cache_dir')
    let dir = g:jj_cache_dir
  else
    let dir = a:root . '/.jj/vim-jj/cache'
  endif
  return empty(dir) ? '' : dir . '/' . sha256(a:key) . '.json'
endfunction

function! s:DiskCacheRead(root, key) abort
  let file = s:DiskCacheFile(a:root, a:key)
  if empty(file) || !filereadable(file)
    return []
  endif
  try
    let data = json_decode(join(readfile(file), "\n"))
  catch
    return []
  endtry
  if type(data) != type({}) || get(data, 'key', '') !=# a:key
    return []
  endif
  return get(data, 'lines', [])
endfunction

function! s:DiskCacheWrite(root, key, lines) abort
  let file = s:DiskCacheFile(a:root, a:key)
  if empty(file)
    return
  endif
  let dir = fnamemodify(file, ':h')
  try
    if !isdirectory(dir)
      call mkdir(dir, 'p', 0700)
    endif
    call writefile([json_encode({'key': a:key, 'lines': a:lines})], file)
  catch
    return
  endtry
  let files = glob(dir . '/*.json', 1, 1)
  if len(files) > 50
    call sort(files, {a, b -> getftime(a) - getftime(b)})
    for stale in files[: len(files) - 51]
      call delete(stale)
    endfor
  endif
endfunction

function! s:BlameStartJob(root, argv, bufnr, key) abort
  let ctx = {'out': [], 'err': [], 'bufnr': a:bufnr, 'key': a:key,
        \ 'root': a:root, 'closed': 0, 'status': -1}
  if exists('*job_start')
    " Vim: out/err arrive line-wise; close_cb and exit_cb can come in
    " either order, so finish only once we have both.
    call job_start(a:argv, {
          \ 'out_cb': {ch, msg -> add(ctx.out, msg)},
          \ 'err_cb': {ch, msg -> add(ctx.err, msg)},
          \ 'close_cb': function('s:BlameJobClose', [ctx]),
          \ 'exit_cb': function('s:BlameJobExit', [ctx])})
  else
    call jobstart(a:argv, {
          \ 'stdout_buffered': v:true,
          \ 'stderr_buffered': v:true,
          \ 'on_stdout': {id, data, ev -> extend(ctx.out, data)},
          \ 'on_stderr': {id, data, ev -> extend(ctx.err, data)},
          \ 'on_exit': {id, status, ev -> s:BlameJobDone(ctx, status)}})
  endif
endfunction

function! s:BlameJobClose(ctx, channel) abort
  let a:ctx.closed = 1
  if a:ctx.status >= 0
    call s:BlameJobDone(a:ctx, a:ctx.status)
  endif
endfunction

function! s:BlameJobExit(ctx, job, status) abort
  let a:ctx.status = a:status
  if a:ctx.closed
    call s:BlameJobDone(a:ctx, a:status)
  endif
endfunction

function! s:BlameJobDone(ctx, status) abort
  let lines = a:ctx.out
  while !empty(lines) && lines[-1] ==# ''
    call remove(lines, -1)
  endwhile
  if !bufexists(a:ctx.bufnr)
    return
  endif
  let wins = win_findbuf(a:ctx.bufnr)
  if empty(wins)
    return
  endif
  if a:status != 0
    let s:blame_fill = ['jj file annotate failed:']
          \ + filter(a:ctx.err + lines, '!empty(v:val)')
    echohl WarningMsg | echomsg 'jj: blame failed' | echohl NONE
  else
    call s:BlameCacheStore(a:ctx.root, a:ctx.key, lines)
    let s:blame_fill = lines
  endif
  call win_execute(wins[0], 'call s:BlameFillHere(s:blame_fill, 0)')
endfunction

" Wait for a pending blame to fill in (up to {timeout} seconds, default
" 15); mostly useful for scripting and tests.  Returns 1 when nothing is
" pending anymore.
function! jj#BlameWait(...) abort
  let deadline = localtime() + (a:0 ? a:1 : 15)
  while localtime() <= deadline
    let pending = 0
    for winnr in range(1, winnr('$'))
      if get(getbufvar(winbufnr(winnr), 'jj_blame', {}), 'pending', 0)
        let pending = 1
      endif
    endfor
    if !pending
      return 1
    endif
    sleep 20m
  endwhile
  return 0
endfunction

" Give each change id in the blame column a stable color, like fugitive's
" rotating hash colors (and jj's own colored output).
let s:blame_cterm = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]

function! s:BlameColors(lines) abort
  let seen = {}
  for line in a:lines
    let id = matchstr(line, '^[k-z]\+\ze\%(\s\|$\)')
    if empty(id) || has_key(seen, id)
      continue
    endif
    let seen[id] = 1
    let n = 0
    for i in range(len(id))
      let n += char2nr(id[i])
    endfor
    let cterm = s:blame_cterm[n % len(s:blame_cterm)]
    let group = 'jjBlameId_' . id
    if !hlexists(group)
      exe 'hi def ' . group . ' ctermfg=' . cterm . ' guifg=' . s:XtermHex(cterm)
    endif
    exe 'syn match ' . group . ' /^' . id . '\>/ nextgroup=jjblameAuthor skipwhite'
  endfor
endfunction

function! s:BlameRestore(blame) abort
  let origin = get(a:blame, 'origin', 0)
  if origin && win_id2win(origin)
    call win_execute(origin, get(a:blame, 'restore', ''))
  endif
endfunction

" Open the commit for the blame line, or with a truthy extra argument the
" blamed file as of that commit (gf).
function! s:BlameJump(cmd, ...) abort
  let blame = get(b:, 'jj_blame', {})
  if empty(blame)
    return
  endif
  let root = b:jj_root
  let change = matchstr(getline('.'), '^\S\+')
  if empty(change)
    return
  endif
  let lnum = line('.')
  try
    let cid = s:ResolveRev(root, change)
  catch /^jj:/
    echohl ErrorMsg | echomsg v:exception | echohl NONE
    return
  endtry
  let url = s:Url(root, cid, a:0 && a:1 ? blame.path : '')
  if empty(a:cmd)
    " Like fugitive's <CR>: leave blame, show the commit in the origin window.
    let origin = blame.origin
    close
    if win_id2win(origin)
      call win_gotoid(origin)
    endif
    exe 'edit ' . fnameescape(url)
    exe 'silent! keepjumps normal! ' . lnum . 'G'
  else
    if win_id2win(blame.origin)
      call win_gotoid(blame.origin)
    endif
    exe a:cmd . ' ' . fnameescape(url)
  endif
endfunction

" Section: ANSI color rendering
"
" jj's terminal output is beautiful; keep it that way.  Output buffers run
" jj with --color always, then the SGR escape codes are stripped and
" re-applied as text properties (Vim) or extmarks (Neovim), with highlight
" groups generated on demand from the xterm-256 palette.  This preserves
" the log graph coloring and jj's bold shortest-unique-prefix change ids.

let s:ansi16 = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee',
      \ '#cd00cd', '#00cdcd', '#e5e5e5', '#7f7f7f', '#ff0000', '#00ff00',
      \ '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff']

function! s:XtermHex(n) abort
  if a:n < 16
    return s:ansi16[a:n]
  elseif a:n < 232
    let n = a:n - 16
    let steps = [0, 95, 135, 175, 215, 255]
    return printf('#%02x%02x%02x', steps[n / 36], steps[(n / 6) % 6], steps[n % 6])
  else
    let gray = 8 + 10 * (a:n - 232)
    return printf('#%02x%02x%02x', gray, gray, gray)
  endif
endfunction

function! s:AnsiSupported() abort
  return get(g:, 'jj_color', 1)
        \ && (exists('*prop_type_add') || exists('*nvim_buf_add_highlight'))
endfunction

let s:ansi_groups = {}

function! s:AnsiGroup(state) abort
  let key = a:state.fg . '_' . a:state.bg
        \ . (a:state.bold ? 'b' : '') . (a:state.underline ? 'u' : '')
  if has_key(s:ansi_groups, key)
    return s:ansi_groups[key]
  endif
  let name = 'jjAnsi_' . substitute(key, '-', 'd', 'g')
  let cmd = 'hi def ' . name
  if a:state.fg >= 0
    let cmd .= ' ctermfg=' . a:state.fg . ' guifg=' . s:XtermHex(a:state.fg)
  endif
  if a:state.bg >= 0
    let cmd .= ' ctermbg=' . a:state.bg . ' guibg=' . s:XtermHex(a:state.bg)
  endif
  let attrs = (a:state.bold ? 'bold,' : '') . (a:state.underline ? 'underline,' : '')
  if !empty(attrs)
    let cmd .= ' cterm=' . attrs[:-2] . ' gui=' . attrs[:-2]
  endif
  exe cmd
  if exists('*prop_type_add') && empty(prop_type_get(name))
    call prop_type_add(name, {'highlight': name})
  endif
  let s:ansi_groups[key] = name
  return name
endfunction

function! s:AnsiApplySGR(state, params) abort
  let ps = map(split(a:params, ';', 1), 'str2nr(v:val)')
  if empty(ps)
    let ps = [0]
  endif
  let i = 0
  while i < len(ps)
    let p = ps[i]
    if p == 0
      call extend(a:state, {'fg': -1, 'bg': -1, 'bold': 0, 'underline': 0})
    elseif p == 1
      let a:state.bold = 1
    elseif p == 4
      let a:state.underline = 1
    elseif p == 22
      let a:state.bold = 0
    elseif p == 24
      let a:state.underline = 0
    elseif p >= 30 && p <= 37
      let a:state.fg = p - 30
    elseif p == 39
      let a:state.fg = -1
    elseif p >= 90 && p <= 97
      let a:state.fg = p - 82
    elseif p >= 40 && p <= 47
      let a:state.bg = p - 40
    elseif p == 49
      let a:state.bg = -1
    elseif p >= 100 && p <= 107
      let a:state.bg = p - 92
    elseif p == 38 || p == 48
      if get(ps, i + 1) == 5
        let a:state[p == 38 ? 'fg' : 'bg'] = get(ps, i + 2, -1)
        let i += 2
      elseif get(ps, i + 1) == 2
        " 24-bit color: not emitted by jj's default config; skip the args
        let i += 4
      endif
    endif
    let i += 1
  endwhile
endfunction

" Strip ANSI escapes from lines; returns [clean_lines, highlights] where
" each highlight is [lnum, byte_col, byte_length, group].
function! s:AnsiRender(lines) abort
  let state = {'fg': -1, 'bg': -1, 'bold': 0, 'underline': 0}
  let clean_lines = []
  let hls = []
  let lnum = 0
  for line in a:lines
    let lnum += 1
    let clean = ''
    let pos = 0
    while pos < len(line)
      let [esc, start, end] = matchstrpos(line, "\e\\[[0-9;]*[ -/]*[@-~]", pos)
      if start < 0
        let chunk = strpart(line, pos)
        let pos = len(line)
      else
        let chunk = strpart(line, pos, start - pos)
        let pos = end
      endif
      if !empty(chunk)
        if state.fg >= 0 || state.bg >= 0 || state.bold || state.underline
          call add(hls, [lnum, len(clean) + 1, len(chunk), s:AnsiGroup(state)])
        endif
        let clean .= chunk
      endif
      if start >= 0 && esc[-1:] ==# 'm'
        call s:AnsiApplySGR(state, matchstr(esc, '^\e\[\zs[0-9;]*'))
      endif
    endwhile
    call add(clean_lines, clean)
  endfor
  return [clean_lines, hls]
endfunction

function! s:AnsiNs() abort
  if !exists('s:ansi_ns')
    let s:ansi_ns = nvim_create_namespace('jj_ansi')
  endif
  return s:ansi_ns
endfunction

function! s:AnsiHighlight(hls) abort
  if exists('*prop_add')
    for [lnum, col, length, group] in a:hls
      call prop_add(lnum, col, {'length': length, 'type': group})
    endfor
  elseif exists('*nvim_buf_add_highlight')
    for [lnum, col, length, group] in a:hls
      call nvim_buf_add_highlight(0, s:AnsiNs(), group, lnum - 1, col - 1, col - 1 + length)
    endfor
  endif
endfunction

" Section: hunk navigation
"
" Like fugitive, ]c and [c jump between @@ hunk headers in plugin buffers
" that show patches (:J diff, :J show, commit object buffers).  In diff
" and merge views these maps are not installed, so Vim's native diff-mode
" ]c/[c apply there, also like fugitive.

function! s:NextHunk(count) abort
  for i in range(a:count)
    call search('^@@', 'W')
  endfor
endfunction

function! s:PrevHunk(count) abort
  normal! 0
  for i in range(a:count)
    call search('^@@', 'Wb')
  endfor
endfunction

function! s:MapHunkNav() abort
  nnoremap <buffer> <silent> ]c :<C-U>call <SID>NextHunk(v:count1)<CR>
  nnoremap <buffer> <silent> [c :<C-U>call <SID>PrevHunk(v:count1)<CR>
endfunction

" Section: command output buffers (:J st, :J log, :J diff, ...)

function! s:OutputFill(lines, color) abort
  setlocal modifiable noreadonly
  if exists('*nvim_buf_clear_namespace')
    call nvim_buf_clear_namespace(0, s:AnsiNs(), 0, -1)
  endif
  silent keepjumps %delete _
  if a:color
    let [clean, hls] = s:AnsiRender(a:lines)
    call setline(1, empty(clean) ? ['(no output)'] : clean)
    call s:AnsiHighlight(hls)
  else
    call setline(1, empty(a:lines) ? ['(no output)'] : a:lines)
  endif
  setlocal nomodified nomodifiable readonly
endfunction

function! s:Output(mods, args, filetype) abort
  let root = s:Root()
  " Remember which file the command was run from, so gf can open it at a
  " commit picked from the output.
  let path = s:BufPathMaybe(root)
  " Buffers with a filetype get Vim syntax highlighting; everything else
  " gets jj's own colors.
  let color = empty(a:filetype) && s:AnsiSupported()
  let [lines, status] = s:JJ(root, a:args, 0, color)
  if status && empty(lines)
    call s:throw('command failed: jj ' . join(a:args, ' '))
  endif
  let mods = empty(s:Mods(a:mods)) ? 'botright ' : s:Mods(a:mods)
  exe 'silent keepalt ' . mods . 'new'
  setlocal buftype=nofile bufhidden=wipe noswapfile nowrap
  silent! exe 'file ' . fnameescape('jj-out://' . join(a:args, ' '))
  let b:jj_root = root
  let b:jj_args = a:args
  let b:jj_color = color
  let b:jj_path = path
  call s:OutputFill(lines, color)
  if !empty(a:filetype)
    let &l:filetype = a:filetype
  endif
  nnoremap <buffer> <silent> q :close<CR>
  nnoremap <buffer> <silent> R :call <SID>OutputRefresh()<CR>
  nnoremap <buffer> <silent> <CR> :<C-U>call <SID>OutputOpen('edit')<CR>
  nnoremap <buffer> <silent> o :<C-U>call <SID>OutputOpen('split')<CR>
  nnoremap <buffer> <silent> O :<C-U>call <SID>OutputOpen('tabedit')<CR>
  nnoremap <buffer> <silent> gf :<C-U>call <SID>OutputGf()<CR>
  call s:MapHunkNav()
  if status
    echohl WarningMsg | echomsg 'jj exited with an error' | echohl NONE
  endif
  " Shrink the window if the output is short.
  if line('$') < winheight(0) && a:mods !~# 'vert'
    exe 'resize ' . max([line('$'), 1])
  endif
  return ''
endfunction

function! s:OutputRefresh() abort
  let [lines, status] = s:JJ(b:jj_root, b:jj_args, 0, get(b:, 'jj_color', 0))
  call s:OutputFill(lines, get(b:, 'jj_color', 0))
endfunction

" Resolve the change id (or commit id) on the current output line to a
" full commit id; returns '' (with a message) if there isn't one.
function! s:OutputResolveLine() abort
  let line = getline('.')
  let token = matchstr(line, '\<[k-z]\{8,}\>')
  if empty(token)
    let token = matchstr(line, '\<[k-z]\{4,}\>')
  endif
  if empty(token)
    let token = matchstr(line, '\<\x\{6,}\>')
  endif
  if empty(token)
    echo 'jj: no revision found on this line'
    return ''
  endif
  try
    return s:ResolveRev(b:jj_root, token)
  catch /^jj:/
    echohl ErrorMsg | echomsg v:exception | echohl NONE
    return ''
  endtry
endfunction

" <CR>/o/O: open the commit on the current line, e.g. from :J log or
" :J status output.
function! s:OutputOpen(cmd) abort
  let cid = s:OutputResolveLine()
  if !empty(cid)
    exe a:cmd . ' ' . fnameescape(s:Url(b:jj_root, cid, ''))
  endif
endfunction

" gf: open the file this output window was created from, as of the commit
" on the current line.
function! s:OutputGf() abort
  let path = get(b:, 'jj_path', '')
  if empty(path)
    echo 'jj: this window has no associated file; use :J edit <rev>:<path>'
    return
  endif
  let cid = s:OutputResolveLine()
  if !empty(cid)
    exe 'edit ' . fnameescape(s:Url(b:jj_root, cid, path))
  endif
endfunction

let s:diff_format_flags = '^\%(-s\|--summary\|--stat\|--types\|--git\|--color-words\|--name-only\|--tool\|-t\)'

" Section: statusline

let s:statusline_cache = {}

" Statusline component: shortest change id of @, with markers for conflict
" (!) and empty (+).  Cached for a few seconds per workspace; runs with
" --ignore-working-copy so it never snapshots or takes the workspace lock.
" Usage: set statusline+=%{jj#Statusline()}
function! jj#Statusline() abort
  let root = jj#Root()
  if empty(root)
    return ''
  endif
  let now = localtime()
  let cached = get(s:statusline_cache, root, [])
  if len(cached) == 2 && now - cached[0] < 10
    return cached[1]
  endif
  let [out, status] = s:JJ(root, ['log', '--no-graph', '-r', '@', '-T',
        \ 'change_id.shortest(8) ++ if(conflict, "!", "") ++ if(empty, "", "+")'], 1)
  let str = status || empty(out) ? '' : '[jj:' . out[0] . ']'
  let s:statusline_cache[root] = [now, str]
  return str
endfunction

" Section: :J dispatcher

" Section: :J browse
"
" Yank (and optionally open) a permalink to the current line on the git
" host, pinned at a commit - fugitive's :GBrowse, jj-flavored.  The web
" URL comes from the repo's git remote (origin, or the sole remote).

function! s:RemoteToWeb(url) abort
  let url = substitute(a:url, '\.git$', '', '')
  let m = matchlist(url, '^\%(https\=\|git\|ssh\)://\%([^@/]*@\)\=\([^/]\+\)/\(.\+\)$')
  if !empty(m)
    return 'https://' . m[1] . '/' . m[2]
  endif
  " scp-like: [user@]host:owner/repo
  let m = matchlist(url, '^\%([^@/]*@\)\=\([^:/]\+\):\(.\+\)$')
  if !empty(m)
    return 'https://' . m[1] . '/' . m[2]
  endif
  return ''
endfunction

" Percent-encode a repo-relative path for use in a URL, byte-wise.
function! s:UrlPath(path) abort
  let out = ''
  for i in range(len(a:path))
    let byte = a:path[i]
    let out .= byte =~# '[A-Za-z0-9/._~-]' ? byte : printf('%%%02X', char2nr(byte))
  endfor
  return out
endfunction

function! s:Browse(bang, line1, line2, count) abort
  let root = s:Root()
  let [remotes, status] = s:JJ(root, ['git', 'remote', 'list'], 1)
  if status
    call s:throw(join(remotes, ' '))
  endif
  let urls = {}
  let order = []
  for line in remotes
    let m = matchlist(line, '^\(\S\+\)\s\+\(\S\+\)$')
    if !empty(m)
      let urls[m[1]] = m[2]
      call add(order, m[1])
    endif
  endfor
  if empty(order)
    call s:throw('no git remote configured; :J git remote add one first')
  endif
  let base = s:RemoteToWeb(urls[has_key(urls, 'origin') ? 'origin' : order[0]])
  if empty(base)
    call s:throw('cannot parse remote url: ' . urls[has_key(urls, 'origin') ? 'origin' : order[0]])
  endif

  let warn = ''
  if bufname('%') =~# '^jj://'
    let [ignored, cid, path] = s:ParseUrl(bufname('%'))
    if empty(path)
      " a commit view: link to the commit itself
      return s:BrowseFinish(base . '/commit/' . cid, a:bang, '')
    endif
  else
    let path = s:BufPath(root)
    " @ only exists locally; pin to the nearest ancestor that a remote
    " actually has.
    try
      let cid = s:ResolveRev(root, 'latest(::@ & remote_bookmarks())')
    catch /^jj:/
      call s:throw('no ancestor of @ is on any remote bookmark; push first')
    endtry
    let [pinned, st] = s:JJContent(root, ['file', 'show', '-r', cid, '--', s:Fileset(path)], 1)
    if st
      call s:throw('file does not exist at pinned commit '
            \ . strpart(cid, 0, 12) . ': ' . join(pinned, ' '))
    endif
    if pinned !=# getline(1, '$')
      let warn = 'buffer differs from pinned commit '
            \ . strpart(cid, 0, 12) . '; line numbers may be off'
    endif
  endif
  if a:count > 0
    let anchor = '#L' . a:line1 . (a:line2 > a:line1 ? '-L' . a:line2 : '')
  else
    let anchor = '#L' . line('.')
  endif
  return s:BrowseFinish(base . '/blob/' . cid . '/' . s:UrlPath(path) . anchor,
        \ a:bang, warn)
endfunction

function! s:BrowseFinish(url, bang, warn) abort
  call setreg('"', a:url)
  if has('clipboard')
    silent! call setreg('+', a:url)
    silent! call setreg('*', a:url)
  endif
  if a:bang
    let opener = has('mac') && executable('open') ? 'open'
          \ : executable('xdg-open') ? 'xdg-open' : ''
    if empty(opener)
      echohl WarningMsg | echomsg 'jj: no browser opener found (xdg-open/open)' | echohl NONE
    elseif exists('*job_start')
      call job_start([opener, a:url])
    elseif exists('*jobstart')
      call jobstart([opener, a:url])
    else
      call system(shellescape(opener) . ' ' . shellescape(a:url) . ' &')
    endif
  endif
  echo a:url
  if !empty(a:warn)
    echohl WarningMsg | echomsg 'jj: ' . a:warn | echohl NONE
  endif
  return ''
endfunction

function! jj#Command(bang, mods, arg, ...) abort
  " Any :J command may change the repo; don't serve stale statuslines.
  let s:statusline_cache = {}
  try
    let args = s:ArgSplit(a:arg)
    let sub = get(args, 0, '')
    let rest = args[1:-1]
    if empty(sub)
      return s:Output(a:mods, ['status'], '')
    elseif sub ==# 'blame' || sub ==# 'annotate'
      return s:Blame(a:mods, rest)
    elseif sub ==# 'browse' || sub ==# 'browse!'
      return s:Browse(a:bang || sub =~# '!$',
            \ a:0 > 0 ? a:1 : 0, a:0 > 1 ? a:2 : 0, a:0 > 2 ? a:3 : 0)
    elseif sub ==# 'diffsplit' || sub ==# 'diffsplit!'
      return s:DiffSplit(a:mods, join(rest, ' '), a:bang || sub =~# '!$')
    elseif sub =~# '^\%(edit\|split\|vsplit\|tabedit\|pedit\)$'
      return s:EditCommand(sub, a:mods, join(rest, ' '))
    elseif sub ==# 'diff'
      let format = !empty(filter(copy(rest), 'v:val =~# s:diff_format_flags'))
      return s:Output(a:mods, args + (format ? [] : ['--git']),
            \ format ? '' : 'diff')
    elseif sub ==# 'show'
      let format = !empty(filter(copy(rest), 'v:val =~# s:diff_format_flags'))
      return s:Output(a:mods, args + (format ? [] : ['--git']), 'jjshow')
    else
      return s:Output(a:mods, args, '')
    endif
  catch /^jj:/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

function! s:CompleteRevset(arglead) abort
  try
    let root = s:Root()
  catch /^jj:/
    return []
  endtry
  let candidates = ['@', '@-', '@--', 'root()', 'trunk()']
  let [out, status] = s:JJ(root, ['bookmark', 'list', '-T', 'name ++ "\n"'], 1)
  if !status
    let candidates += filter(out, '!empty(v:val)')
  endif
  return filter(candidates, 'strpart(v:val, 0, len(a:arglead)) ==# a:arglead')
endfunction

function! jj#Complete(arglead, cmdline, cursorpos) abort
  let subcommands = ['blame', 'browse', 'diff', 'diffsplit', 'edit', 'split', 'vsplit',
        \ 'tabedit', 'pedit', 'status', 'log', 'show', 'describe', 'new',
        \ 'commit', 'squash', 'abandon', 'bookmark', 'rebase', 'restore',
        \ 'resolve', 'undo', 'op', 'workspace', 'file', 'evolog', 'absorb']
  let sub = matchlist(a:cmdline, '^\s*\a\+!\=\s\+\(\S\+\)\s')
  if empty(sub)
    return filter(subcommands, 'strpart(v:val, 0, len(a:arglead)) ==# a:arglead')
  endif
  if index(['edit', 'split', 'vsplit', 'tabedit', 'pedit', 'diffsplit',
        \ 'show', 'new', 'rebase'], substitute(sub[1], '!$', '', '')) >= 0
    return s:CompleteRevset(a:arglead)
  endif
  return []
endfunction
