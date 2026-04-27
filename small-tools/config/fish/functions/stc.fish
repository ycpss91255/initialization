function stc --description "source tmux config"
    tmux source-file "$HOME/.tmux.conf" && echo "source tmux config"
end
