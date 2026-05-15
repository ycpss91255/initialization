function etc --description "Edit the fish configuration file"
    # edited file path
    set -l _file "$HOME/.config/tmux/tmux.conf"

    if test -z "$EDITOR"
        printf "EDITOR environment variable is not set.\n"
        return 1
    end

    if ! test -f "$_file"
        printf "%s is not found.\n" "$_file"
        return 1
    end

    "$EDITOR" "$_file"
end
