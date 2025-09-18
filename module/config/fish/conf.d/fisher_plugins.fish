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
        if not contains "$HOME/workspace" $PROJECT_PATHS
            set -Ux PROJECT_PATHS "$HOME/workspace" $PROJECT_PATHS
        end

        if not contains "$HOME/src" $PROJECT_PATHS
            set -Ux PROJECT_PATHS "$HOME/src" $PROJECT_PATHS
        end
    else
        set -eU PROJECT_PATHS
    end
    # fish-ssh-agent
    if fisher list | grep -q "/fish-ssh-agent"
        if test $SSH_ENV != "$HOME/.ssh/environment"
            set -Ux SSH_ENV "$HOME/.ssh/environment"
        end
    else
        set -eU SSH_ENV
    end
    # # TODO: check fzf config
    # if fisher list | grep -q "/fzf"
    #     set fzf_preview_dir_cmd eza --all --color=always
    # end
end
