" Syntax highlighting for commit views (jj show --git output): the jj
" header, then vim's standard diff highlighting for the patch.  We include
" diff.vim ourselves rather than relying on the stock git filetype, whose
" diff handling varies across vim versions and expects git's own header
" format rather than jj's.

if exists('b:current_syntax')
  finish
endif

syn include @jjshowDiff syntax/diff.vim
unlet! b:current_syntax

" The header and diff regions span the whole buffer, so syntax state can't
" be recovered mid-file; commit views are small, always parse from the top.
syn sync fromstart

syn region jjshowDiffRegion start=/^diff --git / end=/\%$/ contains=@jjshowDiff keepend

syn region jjshowHead start=/\%^/ end=/^\%(diff --git \)\@=/ keepend
      \ contains=jjshowLabel,jjshowChangeId,jjshowCommitId,jjshowEmail,jjshowDate,jjshowConflict,jjshowEmpty
syn match jjshowLabel /^\u[A-Za-z ]\{-}\ze\s*:/ contained
syn match jjshowChangeId /\<[k-z]\{12,}\>/ contained
syn match jjshowCommitId /\<\x\{12,}\>/ contained
syn match jjshowEmail /<[^<>]*>/ contained
syn match jjshowDate /(\d\{4}-\d\d-\d\d[^)]*)/ contained
syn match jjshowConflict /(conflict)/ contained
syn match jjshowEmpty /(empty)/ contained

hi def link jjshowLabel Label
hi def link jjshowChangeId Identifier
hi def link jjshowCommitId Number
hi def link jjshowEmail String
hi def link jjshowDate Comment
hi def link jjshowConflict WarningMsg
hi def link jjshowEmpty MoreMsg

let b:current_syntax = 'jjshow'
