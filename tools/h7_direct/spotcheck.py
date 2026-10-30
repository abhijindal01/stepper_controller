"""Re-read given 32-byte flash words N times each with small reads; report the
majority value per word vs. the image. Usage: spotcheck.py cfg image base off..."""
import re, struct, subprocess, sys, collections
cfg, image, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
offs = [int(x, 0) for x in sys.argv[4:]]
ref = open(image, 'rb').read()
N = 5
cmds = [f'echo "S {o} {r} [read_memory 0x{base+o:08x} 32 8]"' for o in offs for r in range(N)]
tcl = '/tmp/h7_spotcheck.tcl'
open(tcl, 'w').write("\n".join(cmds) + "\n")
p = subprocess.run(['openocd', '-f', cfg, '-c', 'adapter speed 100', '-c', 'init', '-c', f'source {tcl}', '-c', 'exit'],
                   capture_output=True, text=True, timeout=600)
got = collections.defaultdict(list)
for m in re.finditer(r'^S (\d+) \d+ ([0-9a-fx ]+)$', p.stdout + p.stderr, re.M):
    w = m.group(2).split()
    if len(w) == 8:
        got[int(m.group(1))].append(b''.join(struct.pack('<I', int(x, 16)) for x in w))
bad = []
for o in offs:
    c = collections.Counter(got[o]); v, n = c.most_common(1)[0] if c else (None, 0)
    ok = v == ref[o:o+32]
    if not ok: bad.append(o)
    print(f"0x{base+o:08x} reads={len(got[o])} majority={n} {'OK' if ok else 'MISMATCH' if v else 'NO READ'}")
print("BAD:", [hex(base+o) for o in bad])
