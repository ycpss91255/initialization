function claude-rm --description 'Trash Claude Code session by customTitle or sessionId prefix'
    if test (count $argv) -eq 0; or test -z "$argv[1]"
        echo "用法: claude-rm <customTitle | sessionId-prefix>"
        return 1
    end
    set -l target $argv[1]
    set -l matches

    # 1. 先用 customTitle 完全比對
    for f in ~/.claude/projects/*/*.jsonl
        set -l title (head -1 $f 2>/dev/null | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('customTitle',''))" 2>/dev/null)
        if test -n "$title"; and test "$title" = "$target"
            set matches $matches $f
        end
    end

    # 2. 沒中再用 sessionId 前綴比對
    if test (count $matches) -eq 0
        for f in ~/.claude/projects/*/*.jsonl
            set -l sid (basename $f .jsonl)
            if string match -q "$target*" $sid
                set matches $matches $f
            end
        end
    end

    if test (count $matches) -eq 0
        echo "找不到符合 \"$target\" 的 session（依 customTitle 或 sessionId 前綴）"
        return 1
    end

    set -l target_ids
    for f in $matches
        set target_ids $target_ids (basename $f .jsonl)
    end

    # 3. 安全檢查：是否有 fork 依賴待刪除的 session
    set -l dependents (python3 ~/.config/fish/_claude_sessions.py | python3 -c "
import json, sys
target_ids = set(sys.argv[1:])
for line in sys.stdin:
    s = json.loads(line)
    if s.get('forked_from') in target_ids:
        label = s['title'] or s['first_user'] or '(untitled)'
        print(label + '  [' + s['session_id'][:8] + ']')
" $target_ids)

    echo "找到 "(count $matches)" 個 session："
    for f in $matches
        set -l sid (basename $f .jsonl)
        echo "  [$sid]  $f"
    end

    if test -n "$dependents"
        echo
        echo "警告：以下 fork session 引用了待刪除的 parent，刪除後可能壞掉："
        for d in (string split \n -- $dependents)
            test -n "$d"; and echo "  - $d"
        end
        echo
        read -P "仍要繼續刪除? 請輸入 'YES' (大寫) 確認: " ans
        if test "$ans" != YES
            echo "取消"
            return 1
        end
    else
        read -P "確認移到垃圾桶? [y/N] " ans
        if test "$ans" != y; and test "$ans" != Y
            echo "取消"
            return 1
        end
    end

    for f in $matches
        gio trash $f
    end
    echo "已移到垃圾桶（可從 GNOME 垃圾桶 / ~/.local/share/Trash 還原）"
end
