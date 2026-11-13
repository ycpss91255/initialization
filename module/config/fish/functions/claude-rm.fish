function claude-rm --description 'Trash Claude Code session(s) by customTitle or sessionId prefix'
    if test (count $argv) -eq 0
        echo "Usage: claude-rm <customTitle | sessionId-prefix>..."
        return 1
    end

    # matches stores base paths: ~/.claude/projects/{project}/{sessionId}
    set -l matches
    set -l unmatched

    for target in $argv
        if test -z "$target"
            continue
        end

        set -l found

        # 1. Try exact customTitle match first (only .jsonl files have titles).
        #    Titles come from _claude_sessions.py so claude-ls and claude-rm
        #    share one rule: the last customTitle in the transcript is the
        #    current name, wherever it sits in the file. A head-N scan misses
        #    /branch and renamed sessions whose title record is far from the
        #    header (issues #33, #419).
        for base in (python3 ~/.config/fish/_claude_sessions.py | python3 -c "
import json, sys
target = sys.argv[1]
for line in sys.stdin:
    s = json.loads(line)
    if s['title'] == target and s['path'].endswith('.jsonl'):
        print(s['path'][:-len('.jsonl')])
" $target)
            if not contains -- $base $found
                set found $found $base
            end
        end

        # 2. Fall back to sessionId prefix match (both .jsonl and UUID dirs)
        if test (count $found) -eq 0
            for f in ~/.claude/projects/*/*.jsonl
                set -l sid (basename $f .jsonl)
                if string match -q "$target*" $sid
                    set -l base (string replace -r '\.jsonl$' '' $f)
                    if not contains -- $base $found
                        set found $found $base
                    end
                end
            end
            for entry in ~/.claude/projects/*/*
                test -d "$entry"; or continue
                set -l name (basename $entry)
                test "$name" = memory; and continue
                if string match -q "$target*" $name
                    if not contains -- $entry $found
                        set found $found $entry
                    end
                end
            end
        end

        if test (count $found) -eq 0
            set unmatched $unmatched $target
        else
            for base in $found
                if not contains -- $base $matches
                    set matches $matches $base
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
    for base in $matches
        set target_ids $target_ids (basename $base)
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
    for base in $matches
        set -l sid (basename $base)
        set -l artifacts
        test -f "$base.jsonl"; and set artifacts $artifacts "$base.jsonl"
        test -d "$base"; and set artifacts $artifacts "$base/"
        echo "  [$sid]  "(string join ", " $artifacts)
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

    for base in $matches
        test -f "$base.jsonl"; and gio trash "$base.jsonl"
        test -d "$base"; and gio trash "$base"
    end
    echo "Moved to trash (recoverable from GNOME Trash / ~/.local/share/Trash)"
end
