import os
from pathlib import Path
from collections import defaultdict

root = Path('.').resolve()
exclude_dirs = {'node_modules', '.next', 'dist', '.git'}
output = root / '_repo_export.txt'

files = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in exclude_dirs]
    for name in filenames:
        p = Path(dirpath) / name
        if any(part in exclude_dirs for part in p.parts):
            continue
        files.append(p)

children = defaultdict(list)
for p in files:
    rel = p.relative_to(root)
    parts = rel.parts
    for i in range(len(parts)):
        parent = parts[:i]
        child = parts[i]
        if child not in children[parent]:
            children[parent].append(child)

def sort_children(parent):
    entries = children.get(parent, [])
    entries.sort(key=lambda x: (not (root / Path(*parent) / x).is_dir(), x.lower()))
    return entries

lines = []
lines.append(str(root))

def add_tree(parent, prefix=''):
    entries = sort_children(parent)
    for i, name in enumerate(entries):
        is_last = i == len(entries) - 1
        connector = 'â””â”€â”€ ' if is_last else 'â”œâ”€â”€ '
        lines.append(prefix + connector + name)
        child_parts = parent + (name,)
        if (root / Path(*child_parts)).is_dir():
            extension = '    ' if is_last else 'â”‚   '
            add_tree(child_parts, prefix + extension)

add_tree(())

def read_text_safely(path: Path):
    try:
        data = path.read_text(encoding='utf-8')
        return data
    except UnicodeDecodeError:
        return path.read_text(encoding='latin-1')

with output.open('w', encoding='utf-8') as f:
    f.write('REPO TREE\n')
    f.write('========\n')
    f.write('\n'.join(lines))
    f.write('\n\n')
    f.write('FILE CONTENTS (latest)\n')
    f.write('======================\n\n')
    for p in sorted(files):
        rel = p.relative_to(root)
        f.write(f'--- FILE: {rel.as_posix()} ---\n')
        try:
            content = read_text_safely(p)
        except Exception as e:
            content = f'[Error reading file: {e}]'
        f.write(content)
        if not content.endswith('\n'):
            f.write('\n')
        f.write('\n')

print(output)
