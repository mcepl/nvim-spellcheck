" in plugin/spellcheck.vim
if exists('g:loaded_spellcheck') | finish | endif " prevent loading file twice

let s:save_cpo = &cpo " save user coptions
set cpo&vim " reset them to defaults

" lua spapi = require("spellcheck")

" " command to run our plugin
" command! Whid lua spapi.spellcheck()
"
" autocmd OptionSet spelllang lua spapi.spelllang_register()

let &cpo = s:save_cpo " and restore after
unlet s:save_cpo

let g:loaded_spellcheck = 1
