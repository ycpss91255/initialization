function __claude_rm_completions
    python3 ~/.config/fish/_claude_sessions.py | python3 -c "
import json, sys
sessions = [json.loads(l) for l in sys.stdin]
id_to_label = {s['session_id']: (s['title'] or s['first_user'] or '(untitled)') for s in sessions}
for s in sessions:
    desc = s['project']
    if s['forked_from']:
        parent = id_to_label.get(s['forked_from'], s['forked_from'][:8])
        desc += ' [fork of ' + parent + ']'
    if s['title']:
        print(s['title'] + chr(9) + desc)
    else:
        # 無標題：用 sessionId 前 8 碼補完，描述顯示首句訊息
        hint = s['first_user'] or '(no message)'
        print(s['session_id'][:8] + chr(9) + hint + ' — ' + desc)
"
end

complete -c claude-rm -f -a "(__claude_rm_completions)"
