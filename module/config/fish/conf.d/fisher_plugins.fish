status is-interactive; or exit
type -q "fisher"; or exit

function _fisher_has --description 'Check if a fisher plugin is installed' \
    --wraps "fisher remove" \
    --argument-names plugin_name
    if test -z "$plugin_name"
        echo "Usage: _fisher_has <plugin_name>"
        return 1
    end

    fisher list | grep -qx "$plugin_name"
end

function _sponge_config
    _fisher_has "meaningful-ooo/sponge"; or return

    if test "$SHELL_SPOKE_PURGE_ONLY_ON_EXIT" != "true"
        set -gx SHELL_SPOKE_PURGE_ONLY_ON_EXIT "true"
    end
end

function _plugin_pj_config
    _fisher_has "oh-my-fish/plugin-pj"; or return

    set -l _pj_dir "$HOME/workspace" "$HOME/src"

    for _dir in $_pj_dir
        if test -d "$_dir"; and ! contains -- "$_dir" $PROJECT_PATHS
            set -gx PROJECT_PATHS "$_dir" $PROJECT_PATHS
        end
    end
end

function _fzf_fish_config
    _fisher_has "PatrickF1/fzf.fish"; or return

    set -l fzf_bin "$HOME/.fzf/bin"

    if test -d "$fzf_bin"; and ! contains -- "$fzf_bin" $PATH
        set -gx PATH "$HOME/.fzf/bin" $PATH
    end
    # set fzf_preview_dir_cmd eza --all --color=always
end

function _ssh_agent_config
    _fisher_has "danhper/fish-ssh-agent"; or return

    set -l _env_file "$HOME/.ssh/environment"

    if test -f "$_env_file"; and test "$SSH_ENV" != "$env_file"
        set -gx SSH_ENV "$env_file"
    end
    # ssh-add
end

_sponge_config
_plugin_pj_config
_fzf_fish_config
_ssh_agent_config
