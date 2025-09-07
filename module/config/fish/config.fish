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

    if command -q -- "bat"
        alias cat="bat"
        alias c="bat"
    end

    if type -q "fisher"
        if fisher list | grep -q "/sponge"
            set -xg sponge_purge_only_on_exit true
        end

        if fisher list | grep -q "/plugin-pj"
            set -gx PROJECT_PATHS "$HOME/workspace"
        end

        if fisher list | grep -q "/fish-ssh-agent"
            set -gx SSH_ENV "$HOME/.ssh/environment"
        end

        # # TODO: check fzf config
        # if fisher list | grep -q "/fzf"
        #     set fzf_preview_dir_cmd eza --all --color=always
        # end
    end
end

