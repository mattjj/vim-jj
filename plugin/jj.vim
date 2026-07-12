" jj.vim - Jujutsu (jj) support for Vim, in the spirit of fugitive.vim
" Maintainer: Matt Johnson <https://github.com/mattjj>

if exists('g:loaded_jj') || &compatible || v:version < 802
  finish
endif
let g:loaded_jj = 1

command! -bang -bar -nargs=* -complete=customlist,jj#Complete JJ
      \ exe jj#Command(<bang>0, <q-mods>, <q-args>)

" exists(':J') is also nonzero when :J is merely a PREFIX of other commands
" (including our own :JJ above), so test for an exact match (== 2).
" Otherwise :J is never defined, and typing :J works only until some other
" plugin adds a second J-prefixed command - then it's E464, ambiguous.
if exists(':J') != 2
  command! -bang -bar -nargs=* -complete=customlist,jj#Complete J
        \ exe jj#Command(<bang>0, <q-mods>, <q-args>)
endif

augroup jj_plugin
  autocmd!
  autocmd BufReadCmd jj://* nested exe jj#BufReadCmd(expand('<amatch>'))
augroup END
