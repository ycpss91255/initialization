function tmuxp-ssh --description 'Load tmuxp remote_template with SESSION_NAME, SSH_TARGET and REMOTE_WORKSPACE'
    argparse -i 'd/detach' 'w/workspace=' -- $argv
    or return

    if test (count $argv) -lt 1
        echo "usage: tmuxp-ssh [-d] [-w <path>] <ssh_target> [session_name]" >&2
        echo "  -w, --workspace <path>  Subdir under remote home (default: '')" >&2
        return 1
    end

    set -l target $argv[1]
    set -l session (test (count $argv) -ge 2; and echo $argv[2]; or string replace -a '.' '_' $target)
    set -l workspace (set -q _flag_workspace; and echo $_flag_workspace; or echo '')

    if string match -q -r '^[/~]|\$' -- $workspace
        echo "tmuxp-ssh: workspace must be a path relative to remote home (no leading / or ~, no \$VAR); got '$workspace'" >&2
        return 1
    end

    env SESSION_NAME=$session SSH_TARGET=$target REMOTE_WORKSPACE=$workspace tmuxp load -d remote_template
    or return

    if not set -q _flag_detach
        tmux attach -t $session
    end
end
