function claude-ls --description 'List Claude Code sessions for current folder (-a/--all all projects, -l/--long details)'
    set long 0
    set show_all 0
    for arg in $argv
        switch $arg
            case --long
                set long 1
            case --all
                set show_all 1
            case '-*'
                # bundled short flags, e.g. -l -a -la -al
                if string match -q -- '*l*' $arg
                    set long 1
                end
                if string match -q -- '*a*' $arg
                    set show_all 1
                end
        end
    end

    set current_project (string replace --all / - $PWD)

    python3 ~/.config/fish/_claude_sessions.py | python3 -c "
import json, os, sys, time
LONG = len(sys.argv) > 1 and sys.argv[1] == '1'
SHOW_ALL = len(sys.argv) > 2 and sys.argv[2] == '1'
CURRENT_PROJECT = sys.argv[3] if len(sys.argv) > 3 else ''
sessions = [json.loads(l) for l in sys.stdin]
if not SHOW_ALL:
    sessions = [s for s in sessions if s['project'] == CURRENT_PROJECT]
by_project = {}
for s in sessions:
    by_project.setdefault(s['project'], []).append(s)

if not by_project:
    print('No sessions found for: ' + CURRENT_PROJECT)
    print('(use -a/--all to list every project)')
    sys.exit(0)

def fmt_age(epoch):
    if not epoch:
        return ''
    diff = time.time() - epoch
    if diff < 0:
        diff = 0
    if diff < 3600:
        return str(int(diff // 60)) + 'm ago'
    if diff < 86400:
        return str(int(diff // 3600)) + 'h ago'
    return str(int(diff // 86400)) + 'd ago'

def fmt_size(n):
    if not n:
        return ''
    n = float(n)
    for unit in ('B', 'KB', 'MB'):
        if n < 1024:
            return str(int(n)) + unit
        n /= 1024
    return str(int(n)) + 'GB'

def label(s):
    name = s['title'] or s['first_user'] or '(untitled)'
    if len(name) > 50:
        name = name[:47] + '...'
    sid = s['session_id'] if LONG else s['session_id'][:8]
    head = name + '  (' + sid + ')'
    if not LONG:
        return head
    extra = []
    if s.get('message_count'):
        extra.append(str(s['message_count']) + ' msg')
    size = fmt_size(s.get('size_bytes'))
    if size:
        extra.append(size)
    model = s.get('model') or ''
    if model.startswith('claude-'):
        model = model[len('claude-'):]
    if model:
        extra.append(model)
    age = fmt_age(s.get('last_epoch'))
    if age:
        extra.append(age)
    if extra:
        head += '  · ' + ' · '.join(extra)
    return head

total = 0
for project in sorted(by_project):
    items = by_project[project]
    total += len(items)
    if SHOW_ALL:
        display = next((s['cwd'] for s in items if s.get('cwd')), project)
        print()
        print('=== ' + display + '  (' + str(len(items)) + ') ===')
    by_id = {s['session_id']: s for s in items}
    children = {}
    roots = []
    for s in items:
        if s['forked_from'] and s['forked_from'] in by_id:
            children.setdefault(s['forked_from'], []).append(s)
        else:
            roots.append(s)
    def render(s, depth):
        prefix = '    ' * (depth - 1) + '└── ' if depth > 0 else ''
        marker = '  [fork]' if s['forked_from'] else ''
        print(prefix + label(s) + marker)
        for c in sorted(children.get(s['session_id'], []), key=lambda x: x['last_epoch'] or 0, reverse=True):
            render(c, depth + 1)
    for r in sorted(roots, key=lambda s: s['last_epoch'] or 0, reverse=True):
        render(r, 0)
" $long $show_all $current_project
end
