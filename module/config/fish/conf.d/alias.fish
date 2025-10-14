

# Common ls alias
alias ll="ls -l"
alias la="ls -la"
alias l="ls -l"

# Replace cd with z
# TODO: wait test
if type -q -- "z"
    alias cd="z"
end

# Replace ls with eza
if command -q -- "eza"
    alias ls="eza"
end

# Replace vim with neovim
if command -q -- "nvim"
    alias vim="nvim"
    alias view="nvim -R"
end

if command -q -- "xdg-open"
    alias xopen="xdg-open"
end

if command -q -- "bat"
    alias cat="bat"
end

if command -q -- "tree"
    alias tree="tree -C"
end
