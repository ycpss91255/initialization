if status is-interactive
    # WSL
    # if not pgrep -x "sshd" >/dev/null
    #    sudo service ssh --full-restart >/dev/null
    # end

    # if dpkg-query -W -f='${db:Status-Abbrev}\n' -- 'snap' 2>/dev/null | grep -q '^ii'; then
end

begin
    for dir in $HOME/.local/bin $HOME/bin
        if test -d $dir; and not contains -- $dir $PATH
            set -gx PATH $dir $PATH
        end
    end
end
