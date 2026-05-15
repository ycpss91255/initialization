function claude-rm --description 'Trash Claude Code session(s) by customTitle or sessionId prefix'
    if test (count $argv) -eq 0
        echo "Usage: claude-rm <customTitle | sessionId-prefix>..."
        return 1
    end

    set -l matches
    set -l unmatched

    for target in $argv
        if test -z "$target"
            continue
        end

        set -l found

        # 1. Try exact customTitle match first
        for f in ~/.claude/projects/*/*.jsonl
            set -l title (head -1 $f 2>/dev/null | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('customTitle',''))" 2>/dev/null)
            if test -n "$title"; and test "$title" = "$target"
                set found $found $f
            end
        end

        # 2. Fall back to sessionId prefix match
        if test (count $found) -eq 0
            for f in ~/.claude/projects/*/*.jsonl
                set -l sid (basename $f .jsonl)
                if string match -q "$target*" $sid
                    set found $found $f
                end
            end
        end

        if test (count $found) -eq 0
            set unmatched $unmatched $target
        else
            for f in $found
                if not contains -- $f $matches
                    set matches $matches $f
                end
            end
        end
    end

    for t in $unmatched
        echo "No session matched \"$t\" (by customTitle or sessionId prefix)"
    end

    if test (count $matches) -eq 0
        return 1
    end

    set -l target_ids
    for f in $matches
        set target_ids $target_ids (basename $f .jsonl)
    end

    # 3. Safety check: any fork sessions depending on the targets?
    set -l dependents (python3 ~/.config/fish/_claude_sessions.py | python3 -c "
import json, sys
target_ids = set(sys.argv[1:])
for line in sys.stdin:
    s = json.loads(line)
    if s.get('forked_from') in target_ids:
        label = s['title'] or s['first_user'] or '(untitled)'
        print(label + '  [' + s['session_id'][:8] + ']')
" $target_ids)

    echo "Found "(count $matches)" session(s):"
    for f in $matches
        set -l sid (basename $f .jsonl)
        echo "  [$sid]  $f"
    end

    if test -n "$dependents"
        echo
        echo "Warning: the following fork sessions reference a parent to be deleted and may break:"
        for d in (string split \n -- $dependents)
            test -n "$d"; and echo "  - $d"
        end
        echo
        read -P "Continue with deletion? Type 'YES' (uppercase) to confirm: " ans
        if test "$ans" != YES
            echo "Cancelled"
            return 1
        end
    else
        read -P "Move to trash? [y/N] " ans
        if test "$ans" != y; and test "$ans" != Y
            echo "Cancelled"
            return 1
        end
    end

    for f in $matches
        gio trash $f
    end
    echo "Moved to trash (recoverable from GNOME Trash / ~/.local/share/Trash)"
end
