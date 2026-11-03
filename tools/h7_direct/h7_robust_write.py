"""Program STM32H7 flash (both banks) over a flaky ST-LINK, safely.

    h7_robust_write.py CFG IMAGE BASE [--erase]

Rules this enforces (each one learnt on the fixture):
  * a flash word is written only when it is known to be BLANK - never write a
    word twice (H7 cannot overwrite; it corrupts ECC). Known blank means
    either majority reads (3 of 4) said so, or this run erased its sector
    (and a spot check read blank) and has not tried to write the word since;
  * a word that cannot be read is never rewritten - abort and say so;
  * a sector that holds anything other than the image or 0xFF (foreign data,
    or a word that landed wrong) is erased and written again - at most
    MAX_ERASE times per run, so a dying link cannot erase forever;
  * the sector holding 0x08000000 is placed first and its first flash word
    (vector table) LAST, on its own, after every other word has verified -
    so an interrupted run leaves an unbootable-but-reachable board, never a
    half bootloader that runs and turns SWD off;
  * --erase erases every sector the image touches first.

Speed: words are read back twice in the same session that wrote them; two
reads that both equal the image are taken as done (a corrupted read does not
turn into exactly the expected 32 bytes). Anything else goes back through the
majority read. STLINK_DIRECT_SPEED (kHz, default 200) and STLINK_DIRECT_BATCH
(flash words per session, default 256) tune it.

The part may report 1 MiB in FLASHSIZE while the die has 2 MiB (the wrapper
checks the flash physically answers); the second bank's sectors are driven
through the bank-2 register block at 0x52002100.
"""
import collections, os, re, struct, subprocess, sys, time

cfg, image, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
OPENOCD = os.environ.get('OPENOCD') or 'openocd'
SPEED = int(os.environ.get('STLINK_DIRECT_SPEED') or 200)
BATCH = int(os.environ.get('STLINK_DIRECT_BATCH') or 256)
erase = "--erase" in sys.argv[4:]
ref = open(image, 'rb').read()
ref += b'\xff' * (-len(ref) % 32)
BLANK = b'\xff' * 32
MAX_ERASE = 3
FLASH, BANK, SECTOR = 0x08000000, 0x100000, 0x20000
VECTORS = FLASH
WAIT = """proc h7_wait {sr_addr what limit} {
    for {set i 0} {$i < $limit} {incr i} {
        set sr [lindex [read_memory $sr_addr 32 1] 0]
        if {($sr & 0x07) == 0} {
            if {$sr & 0x07EE0000} { error [format "H7ERR SR=0x%08x %s" $sr $what] }
            echo "H7OK $what"
            return
        }
    }
    error "H7ERR timeout $what"
}"""


def sector_of(addr):
    """(bank, sector number within the bank) for a flash address."""
    off = addr - FLASH
    return off // BANK, (off % BANK) // SECTOR


def regs(bank):
    r = 0x52002000 + 0x100 * bank
    return {'KEYR': r + 0x04, 'CR': r + 0x0C, 'SR': r + 0x10, 'CCR': r + 0x14}


def unlock(bank):
    g = regs(bank)
    return [f'mww 0x{g["KEYR"]:08x} 0x45670123', f'mww 0x{g["KEYR"]:08x} 0xCDEF89AB',
            f'mww 0x{g["CCR"]:08x} 0x0FEF0000']


def lock(bank):
    return f'mww 0x{regs(bank)["CR"]:08x} 0x00000001'


def name(sec):
    return f'bank {sec[0] + 1} sector {sec[1]} @ 0x{FLASH + sec[0] * BANK + sec[1] * SECTOR:08x}'


def ocd(cmds):
    args = [OPENOCD, '-f', cfg, '-c', f'adapter speed {SPEED}', '-c', 'init']
    for c in cmds:
        args += ['-c', c]
    try:
        p = subprocess.run(args + ['-c', 'exit'], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return ''
    return p.stdout + p.stderr


def read_cmds(addrs, times):
    return [f'echo "S {a} [read_memory 0x{a:08x} 32 8]"' for a in addrs for _ in range(times)]


def parse_reads(text, got):
    for m in re.finditer(r'^S (\d+) ([0-9a-fx ]+)$', text, re.M):
        w = m.group(2).split()
        if len(w) == 8:
            got[int(m.group(1))].append(b''.join(struct.pack('<I', int(x, 16)) for x in w))


def read_words(addrs, need=3):
    """Majority value (>= need agreeing reads) per word; missing = unreadable."""
    got = collections.defaultdict(list)
    res = {}
    for _ in range(6):
        left = [a for a in addrs if a not in res]
        parse_reads(ocd(['reset halt'] + read_cmds(left, need + 1)), got)
        for a in left:
            c = collections.Counter(got[a])
            if c and c.most_common(1)[0][1] >= need:
                res[a] = c.most_common(1)[0][0]
        if len(res) == len(addrs):
            break
        time.sleep(1)
    return res


def matches(got, a):
    """Two reads, both exactly the image: the word holds it."""
    return len(got[a]) >= 2 and all(v == want(a) for v in got[a][:2])


ERASES = collections.Counter()
FRESH = set()        # erased by this run and not written since: known blank


def erase_sector(sec):
    bank, snb = sec
    g = regs(bank)
    for attempt in range(5):
        out = ocd([WAIT, 'reset halt'] + unlock(bank) +
                  [f'mww 0x{g["CR"]:08x} 0x{(snb << 8) | 0x34:08x}',
                   f'mww 0x{g["CR"]:08x} 0x{(snb << 8) | 0xB4:08x}',
                   f'h7_wait 0x{g["SR"]:08x} erase 20000', lock(bank)])
        if 'H7OK erase' in out:
            ERASES[sec] += 1
            print(f'erased {name(sec)}', flush=True)
            # Spot check before trusting the erase for the whole sector.
            start = FLASH + sec[0] * BANK + sec[1] * SECTOR
            spots = [start + k * (SECTOR // 8) for k in range(8)] + [start + SECTOR - 32]
            state = read_words(spots)
            if len(state) == len(spots) and all(v == BLANK for v in state.values()):
                FRESH.update(a for a in words if sector_of(a) == sec)
            else:
                print(f'  {name(sec)} did not read blank everywhere after the erase - '
                      'checking every word before writing it', flush=True)
                FRESH.difference_update(a for a in words if sector_of(a) == sec)
            return
        print(f'erase {name(sec)} attempt {attempt+1} failed: '
              f'{(re.findall(r"H7ERR.*|Error.*", out) or ["no connect"])[0]}', flush=True)
        time.sleep(2)
    sys.exit(f'ABORT: could not erase {name(sec)}')


def want(a):
    return ref[a - base:a - base + 32]


# Every flash word of the image, blank ones included: a blank word in the image
# must read blank on the chip too, or the sector holds foreign data.
words = [base + o for o in range(0, len(ref), 32)]
first = sector_of(VECTORS)
words.sort(key=lambda a: (sector_of(a) != first, a))           # vector sector first
if VECTORS in words:
    words.remove(VECTORS)
    words.append(VECTORS)                                         # ... vectors last
sectors = sorted(set(map(sector_of, words)), key=lambda s: (s != first, s))

if erase:
    for sec in sectors:
        erase_sector(sec)

todo = list(words)
print(f'{sum(want(a) != BLANK for a in todo)} flash words to place in {len(sectors)} '
      f'sector(s) (vector table last)', flush=True)

stall = 0
started = time.monotonic()
while todo:
    # The vector table goes alone, once everything else has verified.
    batch = [a for a in todo[:BATCH] if a != VECTORS] or todo[:1]
    done, blank = set(), []

    # Words not known blank: is each one done, blank, or foreign?
    unknown = [a for a in batch if a not in FRESH]
    if unknown:
        got = collections.defaultdict(list)
        parse_reads(ocd(['reset halt'] + read_cmds(unknown, 2)), got)
        done.update(a for a in unknown if matches(got, a))
        rest = [a for a in unknown if a not in done]
        state = read_words(rest) if rest else {}
        if len(state) < len(rest):
            stall += 1
            if stall >= 6:
                bad = [hex(a) for a in rest if a not in state]
                sys.exit(f'ABORT: cannot read {bad[:8]} reliably - link too poor, or ECC-damaged '
                         f'(then re-run with --erase on a healthy link). Nothing rewritten.')
            print('  readback incomplete, waiting for the link...', flush=True)
            time.sleep(1)
            continue
        stall = 0
        wrong = sorted({sector_of(a) for a in rest if state[a] not in (want(a), BLANK)})
        if wrong:
            pending = set(todo)
            for sec in wrong:
                if ERASES[sec] >= MAX_ERASE:
                    sys.exit(f'ABORT: {name(sec)} still holds wrong data after {MAX_ERASE} '
                             f'erases - check the link before trying again')
                print(f'  {name(sec)} holds other data - erasing it', flush=True)
                erase_sector(sec)
                pending.update(a for a in words if sector_of(a) == sec)
            todo = [a for a in words if a in pending]           # keep the order
            continue
        done.update(a for a in rest if state[a] == want(a))
        blank = [a for a in rest if state[a] == BLANK and want(a) != BLANK]

    known = [a for a in batch if a in FRESH]
    done.update(a for a in known if want(a) == BLANK)            # erased = already right
    blank += [a for a in known if want(a) != BLANK]

    if blank:
        blank.sort()
        banks = sorted({sector_of(a)[0] for a in blank})
        cmds = [WAIT, 'reset halt']
        for b in banks:
            cmds += unlock(b) + [f'mww 0x{regs(b)["CR"]:08x} 0x00000032']
        for a in blank:
            ws = ' '.join('0x%08x' % x for x in struct.unpack('<8I', want(a)))
            cmds.append(f'write_memory 0x{a:08x} 32 {{{ws}}}; '
                        f'h7_wait 0x{regs(sector_of(a)[0])["SR"]:08x} 0x{a:08x} 2000')
        cmds += [lock(b) for b in banks] + read_cmds(blank, 2)
        FRESH.difference_update(blank)       # tried once: never known blank again
        got = collections.defaultdict(list)
        parse_reads(ocd(cmds), got)
        # Two reads equal to the image: done. Anything else (no read, a read
        # that differs) goes back through the majority read next round.
        done.update(a for a in blank if matches(got, a))

    if done:
        todo = [a for a in todo if a not in done]
        rate = (len(words) - len(todo)) / max(time.monotonic() - started, 1e-3)
        print(f'  ok up to 0x{max(done):08x}, {len(todo)} words left'
              + (f', ~{len(todo) / rate / 60:.0f} min to go' if todo else ''), flush=True)

print('ROBUST_WRITE_DONE')
