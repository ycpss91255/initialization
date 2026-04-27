if type -q "fisher"
    # sponge
    if fisher list | grep -q "/sponge"
        if test "$SHELL_SPOKE_PURGE_ONLY_ON_EXIT" != "true"
            set -Ux SHELL_SPOKE_PURGE_ONLY_ON_EXIT true
        end
    else
        set -eU SHELL_SPOKE_PURGE_ONLY_ON_EXIT
    end
    # plugin-pj
    if fisher list | grep -q "/plugin-pj"
        set -l pj_names "Desktop" "src"

        set -l targets
        for pj_name in $pj_names
            set -a targets "$HOME/$pj_name"
        end

        set -l cleaned
        for path in $PROJECT_PATHS $targets
            if test -d $path; and not contains -- $path $cleaned
                set -a cleaned $path
            end
        end

        set -gx PROJECT_PATHS $cleaned
    end
    # fish-ssh-agent
    if fisher list | grep -q "/fish-ssh-agent"
        if test "$SSH_ENV" != "$HOME/.ssh/environment"
            set -Ux SSH_ENV "$HOME/.ssh/environment"
        end
    else
        set -eU SSH_ENV
    end
    if fisher list | grep -q "/fzf"
        set -gx PATH $HOME/.fzf/bin $PATH
        # set fzf_preview_dir_cmd eza --all --color=always
    end
end
