status is-interactive; or exit

function _wsl_func --description 'WSL use function'
    # WSL
    # if ! pgrep -x "sshd" >/dev/null
    #    sudo service ssh --full-restart >/dev/null
    # end

    # if dpkg-query -W -f='${db:Status-Abbrev}\n' -- 'snap' 2>/dev/null | grep -q '^ii'; then
end

function _user_bin_path --description 'Add user bin path to PATH'
    set -l _user_bin_dir "$HOME/.local/bin" "$HOME/bin"

    for _dir in $_user_bin_dir
        if test -d "$_dir"; and ! contains -- "$_dir" $PATH
            set -gx PATH "$_dir" $PATH
        end
    end
end

function _setup_editor --description 'Setup default editor'
    # candidate editors
    set -l _editor_cmd "nvim" "vim" "nano"

    for _cmd in $_editor_cmd
        if command -q -- "$_cmd"
            set -gx EDITOR "$_cmd"
            break
        end
    end

end

_user_bin_path
_setup_editor
