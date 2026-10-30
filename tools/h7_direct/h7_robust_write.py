"""Program STM32H7 sector 0 (bank 1) over a flaky ST-LINK, safely.

    h7_robust_write.py CFG IMAGE BASE [--erase]

Rules this enforces (each one learnt on the fixture):
  * a flash word is written only after majority reads say it is BLANK -
    never write a word twice (H7 cannot overwrite; it corrupts ECC);
  * a word that cannot be read is never rewritten - abort and say so;
  * the first flash word (vector table) is written LAST, so an interrupted
    run leaves an unbootable-but-reachable board, never a half bootloader
    that runs and turns SWD off;
  * --erase erases sector 0 first (needed after any ECC damage).
"""
import collections, os, re, struct, subprocess, sys, time

cfg, image, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
OPENOCD = os.environ.get('OPENOCD') or 'openocd'
erase = "--erase" in sys.argv[4:]
ref = open(image, 'rb').read()
ref += b'\xff' * (-len(ref) % 32)
BLANK = b'\xff' * 32
BATCH = 8
WAIT = """proc h7_wait {what limit} {
    for {set i 0} {$i < $limit} {incr i} {
        set sr [lindex [read_memory 0x52002010 32 1] 0]
        if {($sr & 0x07) == 0} {
            if {$sr & 0x07EE0000} { error [format "H7ERR SR1=0x%08x %s" $sr $what] }
            echo "H7OK $what"
            return
        }
    }
    error "H7ERR timeout $what"
}"""
UNLOCK = ['mww 0x52002004 0x45670123', 'mww 0x52002004 0xCDEF89AB', 'mww 0x52002014 0x0FEF0000']


def ocd(cmds, speed=200):
    args = [OPENOCD, '-f', cfg, '-c', f'adapter speed {speed}', '-c', 'init']
    for c in cmds:
        args += ['-c', c]
    try:
        p = subprocess.run(args + ['-c', 'exit'], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return ''
    return p.stdout + p.stderr


def read_words(offs, need=3):
    """Majority value (>= need agreeing reads) per word; missing = unreadable."""
    got = collections.defaultdict(list)
    cmds = [f'echo "S {o} [read_memory 0x{base+o:08x} 32 8]"' for o in offs for _ in range(need + 1)]
    res = {}
    for _ in range(6):
        for m in re.finditer(r'^S (\d+) ([0-9a-fx ]+)$', ocd(['reset halt'] + cmds), re.M):
            w = m.group(2).split()
            if len(w) == 8:
                got[int(m.group(1))].append(b''.join(struct.pack('<I', int(x, 16)) for x in w))
        for o in offs:
            c = collections.Counter(got[o])
            if c and c.most_common(1)[0][1] >= need:
                res[o] = c.most_common(1)[0][0]
        if len(res) == len(offs):
            break
        time.sleep(2)
    return res


if erase:
    for attempt in range(5):
        out = ocd([WAIT, 'reset halt'] + UNLOCK +
                  ['mww 0x5200200C 0x00000034', 'mww 0x5200200C 0x000000B4',
                   'h7_wait erase 20000', 'mww 0x5200200C 0x00000001'])
        if 'H7OK erase' in out:
            print('sector 0 erased', flush=True)
            break
        print(f'erase attempt {attempt+1} failed: {(re.findall(r"H7ERR.*|Error.*", out) or ["no connect"])[0]}', flush=True)
        time.sleep(3)
    else:
        sys.exit('ABORT: could not erase sector 0')

todo = [o for o in range(0, len(ref), 32) if ref[o:o+32] != BLANK]
todo = todo[1:] + todo[:1] if todo and todo[0] == 0 else todo      # vectors last
print(f'{len(todo)} flash words to place (vector table last)', flush=True)

stall = 0
while todo:
    batch = todo[:BATCH]
    state = read_words(batch)
    if len(state) < len(batch):
        stall += 1
        if stall >= 6:
            bad = [hex(base + o) for o in batch if o not in state]
            sys.exit(f'ABORT: cannot read {bad} reliably - link too poor, or ECC-damaged '
                     f'(then re-run with --erase on a healthy link). Nothing rewritten.')
        print('  readback incomplete, waiting for the link...', flush=True)
        time.sleep(3)
        continue
    stall = 0
    done = [o for o in batch if state[o] == ref[o:o+32]]
    wrong = [o for o in batch if state[o] not in (ref[o:o+32], BLANK)]
    if wrong:
        sys.exit(f'ABORT: words programmed with wrong data {[hex(base+o) for o in wrong]} '
                 f'- re-run with --erase')
    blank = [o for o in batch if state[o] == BLANK]
    if blank:
        cmds = [WAIT, 'reset halt'] + UNLOCK + ['mww 0x5200200C 0x00000032']
        for o in blank:
            words = ' '.join('0x%08x' % x for x in struct.unpack('<8I', ref[o:o+32]))
            cmds.append(f'write_memory 0x{base+o:08x} 32 {{{words}}}; h7_wait 0x{base+o:08x} 2000')
        cmds.append('mww 0x5200200C 0x00000001')
        ocd(cmds)
        # no assumptions about what landed: the next loop re-reads this batch
        continue
    todo = todo[len(done):]
    print(f'  ok up to 0x{base+batch[-1]:08x}, {len(todo)} words left', flush=True)

print('ROBUST_WRITE_DONE')
