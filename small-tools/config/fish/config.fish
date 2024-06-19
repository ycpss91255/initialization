if status is-interactive
    # WSL
    if not pgrep -x "sshd" > /dev/null
       sudo service ssh --full-restart > /dev/null
    end

    # Use Neovim
    if dpkg --get-selections | grep -q "snap[[:space:]]*install"
        if snap list | grep -q "nvim"
            alias vim="nvim"
            alias view="nvim -R"
            setenv EDITOR "nvim"
        end
    else
        setenv EDITOR "vim"
    end

    if dpkg --get-selections | grep -q "xdg-utils[[:space:]]*install"
        alias xopen="xdg-open"
    end

    # use node js version 18, nvim lps dep
    if type -q "fisher"
        if fisher list | grep -q "nvm"
            nvm use 18 >/dev/null 2>&1
        end
    end

    # use node js version 18, nvim lps dep
    if type -q "fisher"
        if fisher list | grep -q "zoxide"
            zoxide init fish | source
        end
    end


    # SSH agent
    setenv SSH_ENV $HOME/.ssh/environment

    function start_agent
        echo "Initializing new SSH agent ..."
        ssh-agent -c | sed 's/^echo/#echo/' > $SSH_ENV
        echo "succeeded"
        chmod 600 $SSH_ENV 
        . $SSH_ENV > /dev/null
        ssh-add
    end

    function test_identities
        ssh-add -l | grep "The agent has no identities" > /dev/null
        if [ $status -eq 0 ]
            ssh-add
            if [ $status -eq 2 ]
                start_agent
            end
        end
    end

    if [ -n "$SSH_AGENT_PID" ]
        ps -ef | grep $SSH_AGENT_PID | grep ssh-agent > /dev/null
        if [ $status -eq 0 ]
            test_identities
        end
    else
        if [ -f $SSH_ENV ]
            . $SSH_ENV > /dev/null
        end
        ps -ef | grep $SSH_AGENT_PID | grep -v grep | grep ssh-agent > /dev/null
        if [ $status -eq 0 ]
            test_identities
        else
            start_agent
        end
    end
end

