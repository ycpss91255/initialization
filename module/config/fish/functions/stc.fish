function stc --description "source tmux config"
    tmux source-file "$HOME/.config/tmux/tmux.conf" && echo "source tmux config"
end
