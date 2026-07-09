function ctop --description "ctop with TERM fixed for tmux (avoids termbox panic)" \
    --wraps "ctop"
    TERM=screen-256color sudo -E /usr/local/bin/ctop $argv
end
