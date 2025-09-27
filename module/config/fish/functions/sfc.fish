function sfc --description 'Source fish config'
    # soured file path
    set -l _file "$HOME/.config/fish/config.fish"

    if ! test -f "$_file"
        printf "%s is not found.\n" "$_file"
        return 1
    end

    source "$_file"; and printf "Sourced %s\n" "$_file"
end
