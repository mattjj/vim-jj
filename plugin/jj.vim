" jj.vim - Jujutsu (jj) support for Vim, in the spirit of fugitive.vim
" Maintainer: Matt Johnson <https://github.com/mattjj>

if exists('g:loaded_jj') || &compatible || v:version < 802
  finish
endif
let g:loaded_jj = 1

command! -bang -bar -nargs=* -complete=customlist,jj#Complete JJ
      \ exe jj#Command(<bang>0, <q-mods>, <q-args>)

if empty(maparg(':J', 'c')) && !exists(':J')
  command! -bang -bar -nargs=* -complete=customlist,jj#Complete J
        \ exe jj#Command(<bang>0, <q-mods>, <q-args>)
endif

augroup jj_plugin
  autocmd!
  autocmd BufReadCmd jj://* nested exe jj#BufReadCmd(expand('<amatch>'))
augroup END
