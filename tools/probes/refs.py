# Usage: python3 refs.py cb.asm 'SYMBOL'...  (needs cfstr and cfstrings.txt next to cb.asm; see build.sh)
import os, re, sys, subprocess
here = os.path.dirname(os.path.abspath(sys.argv[1]))
asm = open(sys.argv[1]).read().split('\n')
funcs = sys.argv[2:]
cf = set(l.split(':')[0][2:].upper() for l in open(os.path.join(here, 'cfstrings.txt')) if l.startswith('0x'))
for f in funcs:
    out = []
    try: start = asm.index(f + ':')
    except ValueError: print('!! missing', f); continue
    page = {}
    for line in asm[start+1:]:
        if re.match(r'^\S.*:$', line): break
        m = re.search(r'adrp\s+(x\d+), \d+\s+; (0x[0-9a-f]+)', line)
        if m: page[m.group(1)] = int(m.group(2), 16); continue
        m = re.search(r'add\s+(x\d+), (x\d+), #(0x[0-9a-f]+)', line)
        if m and m.group(2) in page:
            addr = page[m.group(2)] + int(m.group(3), 16)
            if format(addr, 'X') in cf: out.append(format(addr, 'X'))
    names = subprocess.run([os.path.join(here, 'cfstr')] + list(dict.fromkeys(out)), capture_output=True, text=True).stdout
    print('==', f); print('   ' + ', '.join(re.findall(r'-> "(.*)"', names)))
