function claude-ls --description 'List Claude Code sessions per project, showing fork tree'
    python3 ~/.config/fish/_claude_sessions.py | python3 -c "
import json, sys
sessions = [json.loads(l) for l in sys.stdin]
by_project = {}
for s in sessions:
    by_project.setdefault(s['project'], []).append(s)

def label(s):
    name = s['title'] or s['first_user'] or '(untitled)'
    if len(name) > 50:
        name = name[:47] + '...'
    return name + '  (' + s['session_id'][:8] + ')'

total = 0
for project in sorted(by_project):
    items = by_project[project]
    total += len(items)
    print()
    print('=== ' + project + '  (' + str(len(items)) + ') ===')
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
        for c in sorted(children.get(s['session_id'], []), key=lambda x: x['title'] or x['first_user'] or ''):
            render(c, depth + 1)
    for r in sorted(roots, key=lambda s: s['title'] or s['first_user'] or ''):
        render(r, 0)

print()
print('Total: ' + str(total) + ' sessions')
"
end
