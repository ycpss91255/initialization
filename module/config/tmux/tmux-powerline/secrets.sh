# Local secrets injection for tmux-powerline (tracked — no plaintext lives here).
# Real secrets are stored in gnome-keyring; this file just looks them up via
# libsecret (secret-tool) and exposes the result as an env var.
#
# One-time setup (after regenerating a Gmail app password at
#   https://myaccount.google.com/apppasswords ):
#
#   secret-tool store --label='tmux-powerline gmail' \
#       service tmux-powerline account gmail
#
#   (will prompt; paste the 16-char app password — not saved in shell history)
#
# Verify with:
#   secret-tool lookup service tmux-powerline account gmail
#
# Remove with:
#   secret-tool clear service tmux-powerline account gmail

# Cache the secret in tmux's global session env so we only hit gnome-keyring
# ONCE per tmux server lifetime. tmux-powerline re-sources this file on every
# status refresh (~10× / sec across panes), and gnome-keyring-daemon on
# Ubuntu 24.04 leaks ~5 MB/min when hammered like that — see
# https://gitlab.gnome.org/GNOME/gnome-keyring/-/issues for related reports.
#
# To force re-fetch (e.g. after rotating the app password):
#   tmux setenv -gu TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_PASSWORD
if [ -z "${TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_PASSWORD:-}" ]; then
    _pw=$(secret-tool lookup service tmux-powerline account gmail 2>/dev/null || true)
    if [ -n "$_pw" ]; then
        export TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_PASSWORD="$_pw"
        [ -n "${TMUX:-}" ] && tmux setenv -g TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_PASSWORD "$_pw" 2>/dev/null
    fi
    unset _pw
fi
