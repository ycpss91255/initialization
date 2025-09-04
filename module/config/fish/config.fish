if status is-interactive
    # WSL
    # if not pgrep -x "sshd" >/dev/null
    #    sudo service ssh --full-restart >/dev/null
    # end

    # if dpkg-query -W -f='${db:Status-Abbrev}\n' -- 'snap' 2>/dev/null | grep -q '^ii'; then

    # Replace vim with neovim
    if command -q -- "nvim"
        alias vim="nvim"
        alias view="nvim -R"
        set -gx EDITOR "nvim"
    end

    # Replace ls with eza
    if command -q -- "eza"
        alias ls="eza"
        alias ll="eza -l"
        alias la="eza -la"
        alias l="eza -l"
    end

    if command -q -- "xdg-open"
        alias xopen="xdg-open"
    end

    # SSH agent
    set -gx SSH_ENV $HOME/.ssh/environment

    function start_agent
        echo "Initializing new SSH agent ..."
        ssh-agent -c | sed 's/^echo/#echo/' > $SSH_ENV
        echo "succeeded"
        chmod 600 $SSH_ENV
        source $SSH_ENV >/dev/null
        ssh-add
    end

    function test_identities
        ssh-add -l | grep "The agent has no identities" >/dev/null
        if test $status -eq 0
            ssh-add
            if test $status -eq 2
                start_agent
            end
        end
    end

    if test -n "$SSH_AGENT_PID"
        ps -ef | grep $SSH_AGENT_PID | grep ssh-agent >/dev/null
        if test $status -eq 0
            test_identities
        end
    else
        if test -f $SSH_ENV
            . $SSH_ENV >/dev/null
        end
        ps -ef | grep $SSH_AGENT_PID | grep -v grep | grep ssh-agent >/dev/null
        if test $status -eq 0
            test_identities
        else
            start_agent
        end
    end
end


set -gx sponge_purge_only_on_exit true
