function efc --description "Edit fish config"
    # edited file path
    set -l _file "$HOME/.config/fish/config.fish"

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
