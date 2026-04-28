if status is-interactive; and command -q keychain; and test -r ~/.ssh/config
    set -l keys (awk 'tolower($1) == "identityfile" {sub(/^~/, ENVIRON["HOME"], $2); print $2}' ~/.ssh/config | sort -u)
    if test (count $keys) -gt 0
        set -l marker $XDG_RUNTIME_DIR/keychain.shown
        if test -n "$XDG_RUNTIME_DIR"; and not test -e $marker
            keychain --eval $keys | source
            touch $marker 2>/dev/null
        else
            keychain --quiet --eval $keys | source
        end
    end
end
