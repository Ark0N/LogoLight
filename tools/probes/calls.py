# Usage: python3 calls.py cb.asm 'SYMBOL'...
# Prints what a function does, in order: selectors it sends, C functions it calls, CFStrings
# it references and its conditional branches. Needs cfstr, stubs and cfstrings.txt next to cb.asm.
import os, re, subprocess, sys
here = os.path.dirname(os.path.abspath(sys.argv[1]))
lines = open(sys.argv[1], errors='replace').read().split('\n')
cf = set(l.split(':')[0][2:].upper() for l in open(os.path.join(here, 'cfstrings.txt'), errors='replace') if l.startswith('0x'))
def tool(name, args):
    if not args: return {}
    out = subprocess.run([os.path.join(here, name)] + args, capture_output=True, text=True, errors='replace').stdout
    return dict(re.findall(r'^(\S+?)(?: ->)?:? "?(.*?)"?$', out, re.M))
index = {}
for i, l in enumerate(lines):
    if re.match(r'^\S.*:$', l): index[l[:-1]] = i
for sym in sys.argv[2:]:
    if sym not in index: print('!! missing', sym); continue
    body, page = [], {}
    for line in lines[index[sym] + 1:]:
        if re.match(r'^\S.*:$', line): break
        m = re.search(r'adrp\s+(x\d+), \d+\s+; (0x[0-9a-f]+)', line, re.I)
        if m: page[m.group(1)] = int(m.group(2), 16); continue
        m = re.search(r'add\s+(x\d+), (x\d+), #(0x[0-9a-f]+)', line)
        if m and m.group(2) in page:
            a = format(page[m.group(2)] + int(m.group(3), 16), 'X')
            if a in cf: body.append(('cf', a, line))
            continue
        m = re.search(r'\bbl\s+(\S+)', line)
        if m: body.append(('bl', m.group(1), line)); continue
        m = re.search(r'\b(cbz|cbnz|tbz|tbnz|b\.[a-z]+)\b.*?(0x[0-9a-f]+)', line)
        if m: body.append(('br', m.group(1) + ' ' + m.group(2), line))
    strs = tool('cfstr', sorted({x for k, x, _ in body if k == 'cf'}))
    sels = tool('stubs', sorted({x for k, x, _ in body if k == 'bl' and x.startswith('0x')}))
    print('==', sym)
    for kind, x, line in body:
        at = line.split()[0] if line.split() else ''
        if kind == 'cf': print('  ', at, 'key  ', strs.get(x, x))
        elif kind == 'bl': print('  ', at, 'call ', sels.get(x, x))
        else: print('  ', at, '      ', x)
