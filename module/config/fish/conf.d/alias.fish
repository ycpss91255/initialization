

# Common ls alias
alias ll="ls -l"
alias la="ls -la"
alias l="ls -l"

if command -q -- "eza"
    alias ls="eza"
end

if command -q -- "nvim"
    alias vim="nvim -p"
    alias view="nvim -R"
    # EDITOR is set in config.fish
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

if command -q -- "yazi"
    alias yz="yazi"
end

