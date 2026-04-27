 set number                         " Display line numbers
set nocompatible                    " Do not use vi compatibility mode
syntax on                           " Enable syntax highlighting
set noshowmode                      " Don't show mode since lightline displays it.
set encoding=utf-8                  " Set encoding to UTF-8
set t_Co=256                        " Set terminal colors to 256
set autoindent                      " Enable automatic indentation
set smartindent                     " Enable smart indentation
set expandtab                       " Convert tabs to spaces
set tabstop=4                       " Set tab key to 4 spaces
set softtabstop=4                   " Set soft tab key to 4 spaces
set shiftwidth=4                    " Set >> key to 4 spaces
set cursorline                      " Highlight the current line
set textwidth=80                    " Set the number of characters for automatic line break
set wrap                            " Enable automatic line wrapping
set linebreak                       " Break lines at word boundaries
set wrapmargin=2                    " Set the margin for automatic line wrapping
set scrolloff=15                    " Scroll number at boundary
set laststatus=2                    " Set status line display mode
set ruler                           " Show cursor position
set showmatch                       " Highlight matching parentheses
set hlsearch                        " Highlight search results
set incsearch                       " Incremental search
set autoread                        " Automatically reload the file
set history=1000                    " Set the number of commands to store in history
set listchars=tab:»■,trail:■        " Set display for tabs and trailing spaces
set list                            " Show tabs and trailing spaces
set noerrorbells                    " Turn off error beeps
set visualbell                      " Use visual bell (screen flash)
set showcmd                         " Show current command
set wildmenu                        " Enable command-line completion
set wildmode=longest:list,full      " Set command-line completion mode
set background=dark                 " Set background to dark
set path=.,/usr/include,,**         " Configure file path for better find command usage
set autochdir                       " Automatically switch to the current file's directory
set foldenable                      " Enable folding feature
set foldlevelstart=99               " Automatically expand all folds when opening a file
set foldmethod=indent               " Fold based on indentation
" set mouse=nv                      " Mouse usage to normal and view mode
filetype indent on                  " Enable file type detection and indentation


" Insert mode map
" ;; equivalent to <ESC>
inoremap ;; <ESC>

" Normal mode map
" Ctrl + hjkl equivalent to Ctrl + w hjkl
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l


" F5 to execute the program
nmap <F5> :call CompileRun()<CR>
func! CompileRun()
        exec "w"
    if &filetype == 'python'
        exec "!time python %"
    elseif &filetype == 'java'
        exec "!javac %"
        exec "!time java %<"
    elseif &filetype == 'sh'
        :!time bash %
    endif
endfunc


call plug#begin('/home/' . $USER . '/.vim/bundle')
    " use \cc \cu comment editing
    Plug 'preservim/nerdcommenter'
    " File explorer
    Plug 'preservim/nerdtree', {'on': 'NERDTreeToggle'}
    " Status bar
    Plug 'itchyny/lightline.vim'
    " Startup screen
    Plug 'mhinz/vim-startify'
    " Traditional Chinese documentation
    Plug 'lazywei/vim-doc-tw'
    " Rainbow brackets
    Plug 'frazrepo/vim-rainbow'
    " Auto-complete brackets
    Plug 'jiangmiao/auto-pairs'
    " Special symbols and icons
    Plug 'ryanoasis/vim-devicons'
    " Add more small icons in NERDTree
    Plug 'tiagofumo/vim-nerdtree-syntax-highlight'
    " Git tools
    Plug 'tpope/vim-fugitive'
    " fuzzy find function
    Plug 'Yggdroot/LeaderF'
    " Use :LeaderfInstallCExtension install C extension
    " echo g:Lf_fuzzyEngine_C
    " tags
    Plug 'ludovicchabant/vim-gutentags'
call plug#end()

" lightline status bar color scheme, short mode names
let g:lightline = {
      \ 'colorscheme': 'wombat',
      \ 'active': {
      \   'left': [ [ 'mode', 'paste' ],
      \             [ 'gitbranch', 'readonly', 'filename', 'modified' ] ],
      \ },
      \ 'component_function': {
      \   'gitbranch': 'FugitiveHead',
      \ },
      \ 'mode_map': {
      \   'n' : 'N',
      \   'i' : 'I',
      \   'R' : 'R',
      \   'v' : 'V',
      \   'V' : 'VL',
      \   "\<C-v>": 'VB',
      \   'c' : 'C',
      \   's' : 'S',
      \   'S' : 'SL',
      \   "\<C-s>": 'SB',
      \   't': 'T',
      \ },
      \ }


" indentLine style
let g:indentLine_enable=1
let g:indentLine_char_list=['|', '¦', '┆', '┊']
let g:indentLine_conceallevel=2
" JSON and Markdown maybe need disable
" let g:vim_json_conceal=0
" let g:markdown_syntax_conceal=0


" nerdtree
let g:NERDTreeWinPos="right"        " NERDTree Display Window Position
nmap <C-n> :NERDTreeToggle<CR>      " Ctrl+N to open and hide NERDTree


" nerdcommenter
let g:NERDSpaceDelims=1             " Automatically add a space when commenting
let g:NERDCompactSexyComs=1         " Use compact syntax for prettified multi-line comments
let g:NERDTrimTrailingWhitespace=1  " Enable trimming of trailing whitespace when uncommenting
" let g:NERDCommentEmptyLines=1       " Allow commenting and inverting empty lines
" let g:NERDAltDelims_java=1          " Set a language to use its alternate delimiters by default
" let g:NERDToggleCheckAllLines=1     " check all selected lines is commented or not


" LeaderF & gutentags
let $GTAGSLABEL='native-pygments'
let $GTAGSCONF='/etc/gtags/gtags.conf'
" let $GTAGSCONF='.globalrc'

" 所生成的数据文件的名称
let g:gutentags_ctags_tagfile='.tags'

" 同时开启 ctags 和 gtags 支持：
let g:gutentags_modules = []
if executable('ctags')
    let g:gutentags_modules += ['ctags']
endif
if executable('gtags-cscope') && executable('gtags')
    let g:gutentags_modules += ['gtags_cscope']
endif



" 配置 ctags 的参数，老的 Exuberant-ctags 不能有 --extra=+q，注意
let g:gutentags_ctags_extra_args = ['--fields=+niazS', '--extra=+q']
let g:gutentags_ctags_extra_args += ['--c++-kinds=+pxI']
" let g:gutentags_ctags_extra_args += ['--c++-kinds=+px']
let g:gutentags_ctags_extra_args += ['--c-kinds=+px']

" 如果使用 universal ctags 需要增加下面一行，老的 Exuberant-ctags 不能加下一行
let g:gutentags_ctags_extra_args += ['--output-format=e-ctags']

" 禁用 gutentags 自动加载 gtags 数据库的行为
let g:gutentags_auto_add_gtags_cscope=0

" gutentags LeaderF 搜索工程目录的标志，当前文件路径向上递归直到碰到这些文件/目录名
let s:repos = ['.git', '.svn', '.hg', '.project', '.root']
let g:gutentags_project_root =s:repos
let g:Lf_WorkingDirectoryMode = 'AF'
let g:Lf_RootMarkers=s:repos

let g:Lf_UseVersionControlTool=1
let g:Lf_DefaultExternalTool='rg'
let g:Lf_PreviewInPopup = 1
let g:Lf_WindowHeight = 0.30


let g:Lf_GtagsAutoGenerate = 0
let g:Lf_GtagsGutentags = 1
" 将自动生成的 tags 文件全部放入 ~/.cache/tags 目录中，避免污染工程目录 "
let s:cachedir = expand('~/.cache/tags')
let g:Lf_CacheDirectory = s:cachedir
let g:gutentags_cache_dir = expand(g:Lf_CacheDirectory.'/LeaderF/gtags')
" 检测 ~/.cache/tags 不存在就新建 "
if !isdirectory(g:gutentags_cache_dir)
   silent! call mkdir(g:gutentags_cache_dir, 'p')
endif



" let g:Lf_Gtagsconf = '/etc/gtags/gtags.conf'
" let g:Lf_Gtagslabel = 'native-pygments'
" let g:Lf_StlColorscheme = 'powerline'
" let g:Lf_GtagsSource = 1

let g:Lf_PreviewResult = {
        \ 'File': 0,
        \ 'Buffer': 0,
        \ 'Mru': 0,
        \ 'Tag': 0,
        \ 'BufTag': 1,
        \ 'Function': 1,
        \ 'Line': 1,
        \ 'Colorscheme': 0,
        \ 'Rg': 0,
        \ 'Gtags': 0
        \}

let g:Lf_ShortcutF='<c-p>'
let g:Lf_ShortcutB='<c-l>' " ???

" There will be ERROR below but it can be executed normally.
noremap <leader>f :LeaderfSelf<cr>
noremap <leader>fm :LeaderfMru<cr>
noremap <leader>ff :LeaderfFunction<cr>
noremap <leader>fb :LeaderfBuffer<cr>
noremap <leader>ft :LeaderfBufTag<cr>
noremap <leader>fl :LeaderfLine<cr>
noremap <leader>fw :LeaderfWindow<cr>
noremap <leader>frr :LeaderfRgRecall<cr>

nmap <unique> <leader>fr <Plug>LeaderfRgPrompt
nmap <unique> <leader>fra <Plug>LeaderfRgCwordLiteralNoBoundary
nmap <unique> <leader>frb <Plug>LeaderfRgCwordLiteralBoundary
nmap <unique> <leader>frc <Plug>LeaderfRgCwordRegexNoBoundary
nmap <unique> <leader>frd <jlug>LeaderfRgCwordRegexBoundary

vmap <unique> <leader>fra <Plug>LeaderfRgVisualLiteralNoBoundary
vmap <unique> <leader>frb <Plug>LeaderfRgVisualLiteralBoundary
vmap <unique> <leader>frc <Plug>LeaderfRgVisualRegexNoBoundary
vmap <unique> <leader>frd <Plug>LeaderfRgVisualRegexBoundary

nmap <unique> <leader>fgd <Plug>LeaderfGtagsDefinition
nmap <unique> <leader>fgr <Plug>LeaderfGtagsReference
nmap <unique> <leader>fgs <Plug>LeaderfGtagsSymbol
nmap <unique> <leader>fgg <Plug>LeaderfGtagsGrep

vmap <unique> <leader>fgd <Plug>LeaderfGtagsDefinition
vmap <unique> <leader>fgr <Plug>LeaderfGtagsReference
vmap <unique> <leader>fgs <Plug>LeaderfGtagsSymbol
vmap <unique> <leader>fgg <Plug>LeaderfGtagsGrep

noremap <leader>fgo :<C-U><C-R>=printf("Leaderf! gtags --recall %s", "")<CR><CR>
noremap <leader>fgn :<C-U><C-R>=printf("Leaderf gtags --next %s", "")<CR><CR>
noremap <leader>fgp :<C-U><C-R>=printf("Leaderf gtags --previous %s", "")<CR><CR>

