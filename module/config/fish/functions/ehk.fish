function ehk --description "Edit fish user key bindings"
    # edited file path
    set -l _file "$HOME/.config/fish/functions/fish_user_key_bindings.fish"

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
