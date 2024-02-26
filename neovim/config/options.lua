vim.g.editorconfig = 0

local options = {
    autochdir = true, -- Change working directory to the file's directory
    cmdheight = 2, -- Height of the command line area
    cmdwinheight = 10, -- Height of the command window when opened
    colorcolumn = '80,120', -- Highlight columns at these character counts to help maintain line length
    completeopt = 'menu,menuone,noselect', -- Options for code completion menu
    conceallevel = 0, -- Do not hide text (e.g., in markdown or LaTeX files)
    foldmethod = 'indent', -- Use indentation level for folding
    hlsearch = true, -- Highlight search matches
    textwidth = 80, -- Set the maximum number of characters for automatic line break
    scrolloff = 10, -- Keep 15 lines visible when scrolling
    showmatch = true, -- When a bracket is inserted, briefly jump to the matching one
    smartindent = true, -- Enable smart indentation
    wrapmargin = 2, -- Margin for line wrapping
}

return options
