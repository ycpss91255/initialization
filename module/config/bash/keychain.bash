# ssh-agent via keychain (shared with fish — see ~/.config/fish/conf.d/keychain.fish)
if [[ $- == *i* ]] && command -v keychain >/dev/null && [[ -r ~/.ssh/config ]]; then
    mapfile -t _keychain_keys < <(awk 'tolower($1) == "identityfile" {sub(/^~/, ENVIRON["HOME"], $2); print $2}' ~/.ssh/config | sort -u)
    if [[ ${#_keychain_keys[@]} -gt 0 ]]; then
        if [[ -n "${XDG_RUNTIME_DIR:-}" && ! -e "$XDG_RUNTIME_DIR/keychain.shown" ]]; then
            eval "$(SHELL=/bin/bash keychain --eval "${_keychain_keys[@]}")"
            touch "$XDG_RUNTIME_DIR/keychain.shown" 2>/dev/null
        else
            eval "$(SHELL=/bin/bash keychain --quiet --eval "${_keychain_keys[@]}")"
        fi
    fi
    unset _keychain_keys
fi
