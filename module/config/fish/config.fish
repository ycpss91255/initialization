if status is-interactive
    # WSL
    # if not pgrep -x "sshd" >/dev/null
    #    sudo service ssh --full-restart >/dev/null
    # end

    # if dpkg-query -W -f='${db:Status-Abbrev}\n' -- 'snap' 2>/dev/null | grep -q '^ii'; then
end

if not contains $HOME/.local/bin $PATH and test -d $HOME/.local/bin
    set -Ux PATH $HOME/.local/bin $PATH
end

if not contains $HOME/bin $PATH and test -d $HOME/bin
    set -Ux PATH $HOME/.local/bin $PATH
end
