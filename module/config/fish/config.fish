if status is-interactive
    # WSL
    # if not pgrep -x "sshd" >/dev/null
    #    sudo service ssh --full-restart >/dev/null
    # end

    # if dpkg-query -W -f='${db:Status-Abbrev}\n' -- 'snap' 2>/dev/null | grep -q '^ii'; then

    # Replace vim with neovim
    if command -q -- "nvim"
        alias vim="nvim"
        alias view="nvim -R"
        set -gx EDITOR "nvim"
    end

    # Replace ls with eza
    if command -q -- "eza"
        alias ls="eza"
        alias ll="eza -l"
        alias la="eza -la"
        alias l="eza -l"
    end

    if command -q -- "xdg-open"
        alias xopen="xdg-open"
    end

end

