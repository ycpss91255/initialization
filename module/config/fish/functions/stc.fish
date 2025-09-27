function stc --description "Source tmux config"
    # soured file path
    set -l _file "$HOME/.config/tmux/tmux.conf"

    # check installed tmux
    if ! command -q -- "tmux"
        echo "tmux is not installed."
        return 1
    end

    # check running tmux server
    if ! tmux info &>/dev/null
        echo "No tmux server is running."
        return 1
    end

    if ! test -f "$_file"
        printf "%s is not found.\n" "$_file"
        return 1
    end

    tmux source-file "$_file"; and printf "Sourced %s\n" "$_file"
end
