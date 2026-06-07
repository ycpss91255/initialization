status is-interactive; or exit

function _wsl_func --description 'WSL use function'
    # WSL
    # if ! pgrep -x "sshd" >/dev/null
    #    sudo service ssh --full-restart >/dev/null
    # end

    # if dpkg-query -W -f='${db:Status-Abbrev}\n' -- 'snap' 2>/dev/null | grep -q '^ii'; then
end

function _user_bin_path --description 'Add user bin path to PATH'
    fish_add_path "$HOME/.local/bin" "$HOME/bin"
end

function _setup_editor --description 'Setup default editor'
    # candidate editors
    set -l _editor_cmd "nvim" "vim" "nano"

    for _cmd in $_editor_cmd
        if command -q -- "$_cmd"
            if test "$_cmd" = "nvim"
                set -gx EDITOR "$_cmd -p"
            else
                set -gx EDITOR "$_cmd"
            end
            break
        end
    end

end

_user_bin_path
_setup_editor
