" Syntax highlighting for :J blame windows.
" Columns (default template): change id, author, date, time, line number.

if exists('b:current_syntax')
  finish
endif

syn match jjblameChangeId /^\S\+/ nextgroup=jjblameAuthor skipwhite
syn match jjblameAuthor /\S\+/ contained nextgroup=jjblameDate skipwhite
syn match jjblameDate /\d\{4}-\d\d-\d\d \d\d:\d\d\%(:\d\d\)\=/ contained nextgroup=jjblameLineNr skipwhite
syn match jjblameLineNr /\d\+\s*$/ contained

hi def link jjblameChangeId Identifier
hi def link jjblameAuthor Type
hi def link jjblameDate Comment
hi def link jjblameLineNr LineNr

let b:current_syntax = 'jjblame'
