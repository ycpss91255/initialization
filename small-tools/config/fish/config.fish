if status is-interactive
    # WSL
    # if not pgrep -x "sshd" > /dev/null
       # sudo service ssh --full-restart > /dev/null
    # end

    # Commands to run in interactive sessions can go here
end

# Use Neovim
if snap list | grep -q "nvim"; then
    alias vim="nvim"
fi

# use node js version 18, nvim lps dep
if type -q "fisher" && fisher list | grep -q "nvm"; then
    nvm use 18 >/dev/null 2>&1
fi

# TODO: add ssh-agent support and ssh-add key support
# if type -q "fisher" && Fisher list | grep -q "ssh-agent"; then
#     ssh-agent fish -c "ssh-add"
#     ssh-agent fish -c "ssh-add ~/.ssh/id_rsa"
# fi

# alias and short function
## Edit fish user key bindings
alias ll="ls -alhF"
alias la="ls -A"
alias l="ls -CF"

function ehk; vim ~/.config/fish/functions/fish_user_key_bindings.fish; end
function shk; source ~/.config/fish/functions/fish_user_key_bindings.fish; end
## fish config
function efc; vim ~/.config/fish/config.fish; end
function sfc; source ~/.config/fish/config.fish && echo "source user config.fish"; end
## tmux config
function etc; vim ~/.tmux.conf; end
function stc; source ~/.tmux.conf; end
