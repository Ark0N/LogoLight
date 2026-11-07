# Usage: python3 whoref.py cb.asm KEY...
# Lists the functions that reference each CFString constant (the reverse of refs.py).
# Needs cfstr and cfstrings.txt next to cb.asm; see build.sh.
import os, re, subprocess, sys
here = os.path.dirname(os.path.abspath(sys.argv[1]))
keys = sys.argv[2:]
addrs = [l.split(':')[0][2:] for l in open(os.path.join(here, 'cfstrings.txt')) if l.startswith('0x')]
structs = [a for a in addrs if int(a, 16) % 0x20 == 0]
names = {}
for i in range(0, len(structs), 200):
    out = subprocess.run([os.path.join(here, 'cfstr')] + structs[i:i + 200], capture_output=True, text=True, errors='replace').stdout
    for m in re.finditer(r'^(\S+) -> "(.*)"$', out, re.M):
        names.setdefault(m.group(2), []).append(int(m.group(1), 16))
wanted = {a: k for k in keys for a in names.get(k, [])}
found = {k: [] for k in keys}
func, page = None, {}
for line in open(sys.argv[1], errors='replace'):
    if re.match(r'^\S.*:$', line):
        func, page = line.strip()[:-1], {}
        continue
    m = re.search(r'adrp\s+(x\d+), \d+\s+; (0x[0-9a-fA-F]+)', line)
    if m:
        page[m.group(1)] = int(m.group(2), 16)
        continue
    m = re.search(r'add\s+(x\d+), (x\d+), #(0x[0-9a-fA-F]+)', line)
    if m and m.group(2) in page:
        addr = page[m.group(2)] + int(m.group(3), 16)
        if addr in wanted and func not in found[wanted[addr]]:
            found[wanted[addr]].append(func)
for k in keys:
    print('==', k, '(%d)' % len(found[k]))
    for f in found[k]:
        print('  ', f)
