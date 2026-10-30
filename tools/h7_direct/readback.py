"""Robust flash readback over a flaky ST-LINK: 256-byte chunks, 3 reads each,
accept a chunk when 2 reads agree. Usage: readback.py cfg base length out.bin"""
import re, struct, subprocess, sys
cfg, base, length, out = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), sys.argv[4]
CH = 256
cmds = []
for off in range(0, length, CH):
    for r in range(3):
        cmds.append(f'echo "R {off} {r} [read_memory 0x{base+off:08x} 32 {CH//4}]"')
tcl = out + '.tcl'
open(tcl, 'w').write("\n".join(cmds) + "\n")
reads = {}
for attempt in range(4):
    p = subprocess.run(['openocd', '-f', cfg, '-c', 'adapter speed 200', '-c', 'init',
                        '-c', f'source {tcl}', '-c', 'exit'], capture_output=True, text=True, timeout=300)
    for m in re.finditer(r'^R (\d+) (\d+) ([0-9a-fx ]+)$', p.stdout + p.stderr, re.M):
        words = m.group(3).split()
        if len(words) == CH // 4:
            reads.setdefault(int(m.group(1)), []).append(b''.join(struct.pack('<I', int(w, 16)) for w in words))
    if all(len(reads.get(o, [])) >= 3 for o in range(0, length, CH)):
        break
img, unsure = bytearray(), []
for off in range(0, length, CH):
    rs = reads.get(off, [])
    best = max(set(rs), key=rs.count) if rs else None
    if best is None or rs.count(best) < 2:
        unsure.append(off); best = best or b'\0' * CH
    img += best
open(out, 'wb').write(img[:length])
print("unsure chunks:", [hex(base + o) for o in unsure])
