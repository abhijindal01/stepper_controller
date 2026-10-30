# ST-LINK pad-test flash handoff (Pi fixture → Flask applet)

**Host:** `assurance` (RPi 4B) · Flask on `:5000` · ST-LINK/V2 `0483:3748` FW **V2J46S7** (clone)  
**OpenOCD:** `/usr/bin/openocd` `0.12.0+rpt…` — probe, erase and readback only  
**st-flash:** `stlink-tools` 1.8.0 — **the write path** (see *Backend*)  
**No NRST** on pogo harness — only SWCLK, SWDIO, GND (+ VTarget sense).  
**Part:** STM32H743**xG**, **1 MiB** flash (confirmed by `st-flash` *and* OpenOCD), 128 KiB pages.

> Read *Backend* and *Mass erase* before flashing anything. On this fixture the
> tool that erases is not the tool that can write, and the one time that was
> ignored the pad was left blank for an afternoon.

This note is the contract for the Flask ST-LINK applet session.

---

## 1. SWD connect / flash recipe (proven on this Pi)

### Working shape

```bash
openocd \
  -f interface/stlink.cfg \
  -c "transport select swd" \
  -c "adapter speed 100" \
  -c "reset_config none" \
  -f target/stm32h7x.cfg \
  -c "init; targets; exit"
```

| Setting | Value | Notes |
|---------|-------|--------|
| Interface | `interface/stlink.cfg` | Prefer this; `stlink-dap.cfg` is deprecated |
| Transport | `swd` | **Not** `hla_swd` |
| Reset | `reset_config none` | No SRST/NRST wire |
| Target | `target/stm32h7x.cfg` | IndiH743 / STM32H743 |
| Speed | start `100`–`1000` kHz for contact bring-up; raise later | |

### Probe results already observed

| Attempt | Result |
|---------|--------|
| `hla_swd` | **FAIL** — `Debug adapter doesn't support 'hla_swd' transport` |
| `swd` / `dapdirect_swd` + `stm32h7x.cfg` | Adapter OK; **Target voltage ≈ 3.28 V**; then **`init mode failed (unable to connect to the target)`** |
| Same + `reset_config none` + 100 kHz | Same connect failure |

Interpretation: ST-LINK USB + VTarget are healthy; SWD session was not established. At probe time the H7 project axis sat at **backward limit (35000)** with forward **67420** — treat contact as **not guaranteed**. Applet **must** seat pogos (H7 project + jog forward / wait for READY) before any OpenOCD call.

### Flash (once `init` succeeds)

Always use the helper script:

```bash
/home/quality/stepper_controller/tools/stlink_flash.sh \
  /home/quality/stepper_controller/firmware/indi_h743/combined.bin
```

It picks a writer (see *Backend*), writes the image and verifies the readback.
Do **not** use OpenOCD `program ... verify exit` or `flash write_image`: on this
H7 + ST-LINK/V2 combo the flash loader download fails part-way through, and
OpenOCD cannot write this board at all (60+ attempts, 12–1000 kHz, AXI SRAM and
SRAM1 work areas).

#### Backend: OpenOCD erases, `st-flash` writes

Reproduced signature of an OpenOCD write on this fixture - note where it dies
(FLASH_CR, i.e. the moment the charge pump starts):

```text
Error: Failed to write memory at 0x24001874          # loader download
Error: error while writing to address 0x5200200c     # FLASH_CR
Error: error during the lock of flash
Error: Error closing APs
unknown/unexpected STLINK status code 0x12 / 0x18
```

`st-flash` (stlink-tools 1.8.0) boots its own loader and completes:

```bash
st-flash --connect-under-reset write /tmp/bl_sector0.bin 0x08000000
# STM32H74x_H75x: 128 KiB SRAM, 1024 KiB flash in at least 128 KiB pages.
# 131072/131072 bytes written
# Flash written and verified! jolly good!
```

so the wrapper resolves a backend automatically:

| `STLINK_BACKEND` | Behaviour |
|------------------|-----------|
| `auto` (default) | `st-flash` when it is installed, OpenOCD otherwise |
| `stflash` | force `st-flash` (fails with exit 1 and an install hint if missing) |
| `ocd` | force the old OpenOCD per-sector path |

The writer never gets to vote on its own work: after `st-flash` reports success
the wrapper reads the flash back with OpenOCD `verify_image` and only then
prints `Verified OK` / `FLASH_OK`. `st-flash` retries are expected - this dongle
fails the first `--connect-under-reset` (`WARN common.c: NRST is not connected`,
`ERROR Soft reset failed: error write to AIRCR`, `Failed to enter SWD mode`) and
succeeds on the next attempt, so the wrapper retries and then trusts the readback
only.

`st-info --probe` is asked for the part size as well; if it disagrees with the
OpenOCD probe the write is refused before anything is erased.

Knobs (environment):

| Variable | Default | Meaning |
|----------|---------|---------|
| `STLINK_SPEED` | `50` | SWD kHz for erase/write (auto-halves on DAP stalls) |
| `STLINK_WORKAREA` | auto | Force the loader RAM address |
| `STLINK_WORKAREA_SIZE` | `0x10000` | Loader RAM size |
| `STLINK_ATTEMPTS` | `3` | Attempts per sector |
| `STLINK_FAST_SPEED` | `200` | kHz climbed to after a sector verifies (`0` = stay slow) |
| `STLINK_MIN_SPEED` | `12` | Slowest kHz the ladder drops to on operand errors |
| `STLINK_RESET_HALT` | `1` | Halt out of reset before erasing (see below) |
| `STLINK_HALT_TRIES` | `4` | Halt attempts before giving up |
| `STLINK_RUN_AFTER` | `1` | `reset run` once the image verifies |
| `STLINK_OPENOCD_TIMEOUT` | `300` | Per-OpenOCD-session timeout (s) |
| `STLINK_FULL_VERIFY` | `1` | Second whole-image verify pass (`0` = per-sector only) |
| `STLINK_PROBE_SIZE` | `1` | Probe the device flash size before writing (see *probed size* below) |
| `STLINK_ALLOW_OVERSIZE` | `0` | Write an image bigger than the probed flash instead of refusing it |
| `STLINK_FLASH_TIMEOUT` | `1800` | Server-side (`stlink.py`) ceiling for the whole flash (s) |
| `STLINK_CONNECT_BACKOFF` | `2` | Seconds before a failed *connect* is retried (0/2/4 s ladder) |
| `STLINK_FLASH_PRECHECK` | `1` | Run a 3-session link check before flashing (`0` = skip) |
| `STLINK_FLASH_PRECHECK_N` / `_MIN` | `3` / `66` | Sessions and pass rate the pre-check needs |
| `STLINK_FLASH_RETRIES` | `2` | Retries of a *transient* link failure (`swd_lost`, `ap_fail`, `halt_fail`) |
| `STLINK_FLASH_RETRY_DELAY` | `2` | Seconds between those retries (multiplied by attempt) |
| `STLINK_BACKEND` | `auto` | `auto` / `stflash` / `ocd` writer (see *Backend*) |
| `STLINK_STFLASH` | `st-flash` | `st-flash` binary used by the wrapper |
| `STLINK_MASS_ERASE` | `0` | Erase the whole flash first (see *Mass erase* - the size check still runs first) |
| `STLINK_VERIFY_OCD` | `1` | Verify the written image with OpenOCD's readback |
| `STLINK_LOG_DIR` | `/tmp` | Where per-session logs (`stlink_flash_*.log`) are kept |
| `STLINK_KEEP_LOGS` | `1` | Keep those logs (`0` = only print them) |
| `STLINK_STFLASH_CONNECT` | `under-reset` | `plain` drops `--connect-under-reset` (the only attach that works on a blank H7) |
| `STLINK_STFLASH_FREQ` | unset | `st-flash --freq=` (`25k`, `5k`) when programming errors appear |
| `STLINK_STFLASH_FLASH` | unset | `st-flash --flash=` (`1M`) when the size probe is marginal |
| `STLINK_RETRY_DELAY` | `2` | Base seconds between `st-flash` attempts (grows 2, 4, 6 … capped at 15) |
| `STLINK_READBACK_PREFLIGHT` | `1` | Require two identical readbacks before any erase |
| `STLINK_READBACK_BYTES` | `0x2000` | Size of the preflight readback |
| `STLINK_BLANK_CHECK` | `1` | After an erase (mass erase / st-flash page erase) require the range to read `0xFF` |
| `STLINK_RAM_INTEGRITY` | `1` | Load a 4 KiB random block into each RAM region and read it back |

### First: is the SWD link healthy?

Reproduced on the fixture: connects alternate between success and
`init mode failed (unable to connect to the target)` **at the same 3.28 V**,
RAM probes fail with `SWD link was lost`, and OpenOCD cannot finish examining
the target:

```text
Error: Failed to write memory at 0xe0002004
Error: [stm32h7x.cpu0] Execution of event examine-end failed:
Error: Failed to read memory at 0xe00e4004
```

Those are **core debug registers** (FPB `0xE0002000+`, DWT `0xE0001000+`),
reached through the same AP as everything else: a failure there is a
link/harness problem, not a flash problem. `Target voltage: 3.28 V` is only the
ST-LINK's VTREF sense, and `contact_ready` only proves the *motor* reached its
limit - neither says the pogo pins carry SWCLK/SWDIO/GND cleanly.

Measure it instead of guessing:

```bash
tools/stlink_soak.sh              # 20 sessions, needs >= 90 %
tools/stlink_soak.sh 50 --min 95  # stricter
STLINK_SPEED=25 tools/stlink_soak.sh
```

Each session counts only if OpenOCD connects, examines the target, writes an
FPB register, halts and reads `DHCSR.S_HALT` back:

```text
link soak: 20 sessions @ 50 kHz, threshold 90 %
  1/20  ok
  2/20  FAIL (connect)
pass rate: 18/20 = 90 % in 62.0s
failures: connect=2
LINK_OK: link is healthy enough to flash
```

Exit `0` = healthy, `1` = below threshold (`LINK_UNHEALTHY`, with a per-kind
triage list), `2` = cannot run. In the dashboard: **Link Check (20)**; the
Full Sequence runs it first and stops if the link is marginal. Server side:
`POST /api/stlink/soak` with optional `{"count": 20, "min_pct": 90}`.

The flash wrapper applies the same rule: if a work-area probe fails for link
reasons (`SWD link lost`, dead AP), it retries that region once and then
aborts with `FLASH_FAILED swd: SWD link unhealthy` - it no longer "succeeds"
on a luckier RAM address after the bus has already dropped.

Harness fixes, in order of payoff:

1. **GND return** - second and/or shorter GND pogo; a single thin ground
   through a moving fixture produces exactly these AP failures.
2. **Contact resistance** - check pogo springs, no series resistor >100 Ω on
   SWCLK/SWDIO, clean pads.
3. **Target power** - bench supply to the pad, 100 nF at the pogo; check the
   rail under load, not the ST-LINK sense pin.
4. **ST-LINK on a powered hub** - clone V2 dongles that re-enumerate after a
   target reset give the alternating connect/fail pattern
   (`dmesg -T | grep -i -E "usb|stlink"`).
5. **Steppers de-energised** while flashing (holding current shares the
   ground).

### Flash loader work area: AXI SRAM, not DTCM

OpenOCD's `target/stm32h7x.cfg` puts the flash-loader work area in **DTCM**
(`-work-area-phys 0x20000000`). On this fixture SWD writes into that window
fail, so the loader is never downloaded and sector 0 never programs — the
erase still succeeds, which makes it look like a flash problem when it is a
RAM/debug-access problem:

```text
erased address 0x08000000 (length 131072) in 0.898930s (142.392 KiB/s)
Error: Failed to write memory at 0x20003994
Error: error writing to flash at address 0x08000000 at offset 0x00000000
flash failed at sector 0 @ 0x8000000
```

`tools/openocd_fixture.cfg` now moves the work area to **AXI SRAM**
(`0x24000000`, 64 KiB), and `tools/stlink_flash.sh` re-checks RAM before it
writes anything, falling back AXI SRAM → SRAM1 (D2) → SRAM4 (D3) → DTCM and
reporting which one it used:

```text
work area AXI SRAM (D1) 0x24000000 - RAM check ok
```

Manual check on the Pi (writes 4 bytes; target is halted, power-cycle after):

```bash
openocd -f tools/openocd_fixture.cfg \
  -c "init; adapter speed 50; halt" \
  -c "mww 0x24000000 0x5AA5C33C; mdw 0x24000000" \
  -c "exit"
# expected: 0x24000000: 5aa5c33c
```

#### The probe has to cover the loader footprint, not the ends of the window

The work area is 64 KiB, but only ~16 KiB of it is used: OpenOCD downloads the
loader blob at the base, then its parameter block and image buffer follow. A
probe that writes one word at `0x24000000` and one at the top of the window
passes while every loader write past a few KiB fails - the log then reads
"RAM check ok" and dies *after* the erase:

```text
work area AXI SRAM (D1) @ 0x24000000 - RAM check ok
  sector 0/12 @ 0x8000000 (131072 bytes, erase 128 KiB)
    attempt 1/3 failed: failed during write (...)
      Error: Failed to write memory at 0x24003074
      Error: error writing to flash at address 0x08000000 at offset 0x00000000
```

The failing offset moves between attempts (`0x1874`, `0x3074`, `0x4074`) - that
is the loader's own buffer, not the base word. `tools/stlink_flash.sh` now
writes a pattern at `0x0, 0x400, 0x800, 0x1000, 0x1874, 0x2000, 0x2800,
0x3074, 0x3994, 0x4000, 0x4074, 0x8000` **plus a 32-word burst at `0x1000`**
and reads it all back, so a window that cannot carry that footprint is rejected
*before* anything is erased:

```text
work area AXI SRAM (D1) @ 0x24000000 - RAM check FAILED at 0x24001000 (...)
work area SRAM1 (D2) @ 0x30000000 - RAM check ok
```

A different region (`SRAM1`/`SRAM4`) is then used for the loader. If no region
survives, the flash stops with exit `2` and nothing is erased - the RAM probe is
the link test, and the same AP carries the loader, so a work area that cannot
hold 16 KiB of pattern will not carry a 128 KiB sector either.

### Server side: link pre-check, retries and selectable speed

`POST /api/stlink/flash` (and `/stlink/flash`) accepts, besides `image`/`base`:

| Field | Default | Meaning |
|-------|---------|---------|
| `speed` | auto (50 kHz) | SWD kHz for this flash; the wrapper walks down from here |
| `precheck` | `true` | Run a 3-session link check first (needs >= 66 %); on failure returns `state: link_unhealthy` and **does not flash** |
| `retries` | `2` | Retry a transient failure (`swd_lost`, `ap_fail`, `halt_fail`) after `2 s x attempt`, re-checking the link in between; non-transient failures (`erase_fail`, `verify_fail`, `no_work_area`) are not retried |

```bash
curl -s -X POST http://127.0.0.1:5000/api/stlink/flash \
  -H 'Content-Type: application/json' \
  -d '{"image": "arducopter_with_bl.hex", "speed": 25, "precheck": true}'
# {"ok": false, "state": "link_unhealthy", "code": 3,
#  "log": "link precheck: 0/3 sessions usable (need 66 %) - not flashing", ...}
```

The dashboard exposes the same thing: a **Speed** selector next to the image
selector, and a `Link Check (20)` button. A blocked flash logs
`Flash blocked: the SWD link failed the pre-check`. Retries are reported as
`Retry: attempt 1/3 failed (swd_lost) - retrying in 2s`.

Rationale: on this fixture a connect failure is transient - the identical
command succeeds seconds later - while a failing erase or verify is not. So
pauses plus a link re-measure are worth it, but only for link-level failures.

### Halting: `reset halt`, never `halt`

`halt` on a **running** app does not stick on this fixture. The core keeps
executing (erratum 3092511 handling reports *"target was in unknown state when
halt was requested"*) and the independent watchdog the app armed resets the
chip a moment later, mid operation:

```text
Warn : [stm32h7x.cpu0] target was in unknown state when halt was requested
Error: erase time-out or operation error sector 0
Error: failed erasing sectors 0 to 0
```

or, when it happens during the write:

```text
Error: error waiting for target flash write algorithm
Error: Fail reading CTRL/STAT register. Force reconnect
Error: error during the lock of flash
```

Erasing bank 0 while the CPU executes out of bank 0 is also how a board ends up
booting from a half-erased vector table (`SP = 0xFFFFFFFF` → lockup loop, and
then every OpenOCD connect fails with `init mode failed (unable to connect to
the target)`).

The wrapper therefore starts **every** sector session with `reset halt`
(SYSRESETREQ + vector catch): the core stops at the reset vector before any
software runs, and IWDG is unarmed after a system reset. The halt is confirmed
by reading `DHCSR` (`0xE000EDF0`, bit 17 `S_HALT`) before anything is erased —
the erase only runs in the `else` branch of a Tcl `catch`, so a core that will
not stop can never be erased underneath.

```text
target halted out of reset
  sector 0/12 @ 0x8000000 (131072 bytes, erase 128 KiB)
    verified (131072 bytes, 61 KiB/s)
    adapter speed -> 100 kHz
```

If `reset halt` cannot be achieved, the wrapper falls back to `halt` plus
stretching IWDG (`KR=0x5555`, `RLR=0xFFF`, `KR=0xAAAA`) and warns that this is
less reliable; if even that fails it exits `4` **without erasing anything**.

Manual recovery of a board stuck in the invalid-vector loop:

```bash
cd /home/quality/stepper_controller
openocd -f tools/openocd_fixture.cfg \
  -c "init; adapter speed 200; reset halt" \
  -c "mdw 0xE000EDF0" \
  -c "program firmware/indi_h743/arducopter_with_bl.hex verify reset exit"
```

`mdw 0xE000EDF0` must show bit 17 set (e.g. `a05f0013`). With the work area and
the halt order both fixed, a single `program ... verify reset exit` is expected
to work; the per-sector loop exists only to keep a failing sector from taking
the rest of the image with it.

### Symptom → cause

| Log | Cause | Action |
|-----|-------|--------|
| `Failed to write memory at 0x2000xxxx` | loader RAM in DTCM | fixed: work area moved to AXI SRAM |
| `Failed to write memory at 0x24001874` / `0x24003074` / `0x24004074`, after `RAM check ok` | the work area answers isolated words but not the loader footprint (link collapsing under sustained writes) | fixed: the probe now writes the footprint + a 32-word burst before erasing; a work area that fails it is skipped |
| `halted due to debug-request ... pc: 0xfffffffe msp: 0xfffffffc` | sector 0 is erased: an earlier run erased the vector table and never wrote it back | reported as `FLASH_EVENT vectors_blank`; flash a full image from `0x08000000` (sector 0 is written last, see below) |
| `flash size probed value 1024k` / `Bank (0) size is 512 kb` with a 1.6 MB image | the part is 1 MiB, not the 2 MiB the tooling assumes | `FLASH_FAILED size:` - build for `FLASH_SIZE_KB 1024` or confirm the part; `STLINK_ALLOW_OVERSIZE=1` forces the write |
| `target was in unknown state when halt was requested` | `halt` did not stop a running app | fixed: `reset halt` + DHCSR check |
| `erase time-out or operation error sector 0` | target reset itself mid-erase (IWDG/brownout) | re-seat, power-cycle the pad, retry (`STLINK_SPEED=25`) |
| `Fail reading CTRL/STAT register. Force reconnect` | SWD link lost (chip reset / contact) | re-seat contact, power-cycle |
| `init mode failed (unable to connect to the target)` | chip in fault/lockup loop, no contact, or SWD too fast for the harness | reported as `FLASH_FAILED swd: target could not be reached`; try `speed: 12-25`, then the manual recovery above |
| `Failed to write/read memory at 0xE000xxxx`, `Execution of event examine-end failed` | core debug registers unreachable: link/AP failing | run `tools/stlink_soak.sh`; fix GND return / contact / target power |
| `FLASH_FAILED swd: SWD link unhealthy` | link died during the work-area probe | same as above - do not retry the flash |
| `no writable RAM for the flash loader` | no halt + no reachable RAM | re-seat, power-cycle, retry |
| `error while writing to address 0x5200200c` + `error during the lock of flash` + `Error closing APs` | the AP dies exactly when FLASH_CR is programmed: **brownout / reset during programming**, not a tool bug | reported as `FLASH_FAILED brownout:`; check pad supply, GND return, bulk capacitance, de-energise the steppers, re-seat and retry |
| `WARN common.c: NRST is not connected`, `ERROR Soft reset failed: error write to AIRCR`, `Failed to enter SWD mode` | `st-flash` could not reset into SWD (clone dongle re-enumerated, or no contact) | retry - the same command succeeds minutes later; `dmesg -T -w` shows the USB resets (grep for `usb`/`stlink`) |
| `FLASH_FAILED stflash:` | `st-flash` failed to write on every attempt | re-run, then `tools/stlink_recover.sh`; move the dongle to a powered hub / direct USB2 port |
| `Flash programming error: 0x00040000` + `stlink_fwrite_flash() == -1` after `131072/131072 bytes written` | `PGSERR`: the flash word was not cleanly erased or the program was torn down; the rest of the write is dropped silently | `brownout` class. Erase first, power-cycle, retry; check supply/VCAP |
| `Error: Failed to read memory at 0x0801d7c8` during a verify | the readback could not happen (ECC bus error from half-programmed words, or the link) | `FLASH_FAILED readback:` — contents **unknown**, not mismatched; erase the page before diagnosing further |
| `two readbacks of the same range disagree` | the link corrupts data it reads | nothing was erased; cable/port/dongle, then power-cycle |
| `no RAM region held a 4 KiB random block` | neither writer can run its loader | nothing was erased; power-cycle (erratum 3092511) and re-seat contact |
| `halted … pc: 0x00000000 msp: 0x00000000` | erratum 3092511 bogus halt on a blank part | `FLASH_FAILED halt:`; power-cycle, then `STLINK_BACKEND=stflash` |
| `did not read back as erased` | the erase did not blank the range, so the program will `PGSERR` | supply/VCAP, power-cycle, retry |
| `st-info reports … KiB` reading 1024× too large | `st-info` 1.8.0 prints **bytes** (`flash: 1048576`) | fixed: the size is converted, and both spellings are accepted |

Exit codes / markers from the wrapper: `0` ok (`FLASH_OK ...`),
`1` usage or image-range error (including an image that does not fit the
probed flash size), `2` no writable work area (`FLASH_FAILED ram: ...`),
`3` flash/verify failed or the link died (`FLASH_FAILED
erase|write|verify|swd|ap: ...`), `4` target would not halt (`FLASH_FAILED
halt: ...`), `5` the board's vector table is blank and the image does not
restore it. In every failure case nothing is erased unless a halt was
confirmed, and every failure message states which sectors were erased but not
written (`erased but NOT written: sector 0 @ 0x08000000, ...`).

`FLASH_WARN ...` lines are advisory (image bigger than the probed flash,
forced writes); `FLASH_EVENT vectors_blank ...` marks a board that is currently
unbootable.

### Sector 0 is written last, and never erased twice

Sector 0 (`0x08000000`, 128 KiB) holds the vector table and the ArduPilot
bootloader. Two rules keep an interrupted flash from bricking the pad:

1. **Order** - a multi-sector image is written `1..N` first and sector 0 last
   (`sector order: 1..12, then 0`). If the link dies at sector 5, the board
   still boots the previous firmware; with the old order it sat on an erased
   sector 0 (`pc 0xfffffffe`, `msp 0xfffffffc`) and every later session had to
   fight a lockup loop.
2. **No second erase** - once a sector's erase has completed, a retry runs
   `write_image` + `verify_image` only (`... is already erased - retrying the
   write only`). Previously three attempts per sector meant three erases of
   sector 0 for one write failure. A *link* failure (`swd`, `ap`) is the
   exception: the erase result is not trustworthy then, so the retry erases
   again.

Before the first erase the wrapper reads the vector table
(`mdw 0x08000000`, `mdw 0x08000004`) and reports what it sees:

```text
vector table ok (SP=0x24080000 PC=0x08000201)
# or, on a board left mid-flash:
FLASH_EVENT vectors_blank SP=0xffffffff PC=0xffffffff
WARNING: sector 0 @ 0x08000000 has no valid vector table - the board cannot boot
```

A blank vector table does **not** block a full image (`0x08000000..`) - that is
the repair. It does block an *app-only* image (`0x08020000`): exit `5`, nothing
erased, because the board would stay unbootable. Power-cycling the pad does not
fix an erased sector 0; only a flash does.

### Probed flash size: this pad reports 1024 KiB

`tools/stlink_flash.sh` now runs `flash probe 0` before writing and prints what
the driver found:

```text
device flash: probed 2048 KiB (0x8000000..0x8200000)
```

On the pad it came back as **1024 KiB** (`flash size probed value 1024k`,
`Bank (0) size is 512 kb`) while the queued image was 1,645,996 bytes
(`0x08000000..0x08191DAC`). Sectors past `0x08100000` do not exist on a 1 MiB
part, so the write would have died there - after erasing everything before it:

```text
FLASH_WARN image does not fit the probed flash size
    image : 0x08000000..0x08191DAC (1645996 bytes)
    device: 0x08000000..0x08100000 (1024 KiB)
FLASH_FAILED size: refusing to write 1645996 bytes into 1024 KiB of flash - nothing was erased
```

**Settled: the part is 1 MiB.** `st-flash` agrees with OpenOCD
(`STM32H74x_H75x: 128 KiB SRAM, 1024 KiB flash in at least 128 KiB pages.`),
`chipid: 0x400` = 1024 KiB (an H743**xG**, or a relabelled H750 - `VIT6` would
be 2 MiB, `VGT6` 1 MiB). The consequences:

| Range | Size | Holds |
|-------|------|-------|
| `0x08000000`–`0x0801FFFF` | 128 KiB | sector 0: vector table + ArduPilot bootloader |
| `0x08020000`–`0x080FFFFF` | **896 KiB** | the application - `text + data` must be ≤ **917,504 B** |

The ArduCopter image that was queued is 1,645,996 bytes (`0x191DAC`), so it
cannot be written to this part no matter which tool writes it. The build needs
`FLASH_SIZE_KB 1024` plus `HAL_MINIMIZE_FEATURES` (and a check of
`arm-none-eabi-size build/IndiH743/bin/arducopter`), or a 2 MiB board.

`/tmp/bl_sector0.bin` (131,072 B, `SP=0x20000600 PC=0x080002E1`) was extracted
from the pad and is the only copy of the bootloader that survived. Sector 0
alone is enough to make the board bootable and reachable again.

`0x08000000`..`0x0801FFFF` (the bootloader sector) is the same either way, so a
sector-0-only write still fits and is enough to make the board bootable again.

### Mass erase: only with a writer that works, and only after the size check

`STLINK_MASS_ERASE=1` erases the whole flash before writing. Two rules make it
safe, both learnt the hard way:

1. **The size check runs first, always.** An image that does not fit the probed
   flash is refused with `FLASH_FAILED size: ... nothing was erased` *before*
   any erase command - even with `STLINK_MASS_ERASE=1`.
2. **Only mass erase when the writer is known to work.** On 2026-10-29 a mass
   erase ran while the write path was broken, and the pad was blank until
   `st-flash --connect-under-reset` got it back. If `st-flash` is not installed
   and the OpenOCD write path has not just succeeded, do not mass erase.

```bash
# erase everything, then write and verify - log line by log line
STLINK_MASS_ERASE=1 tools/stlink_flash.sh /tmp/bl_sector0.bin 0x08000000
#   mass erase requested - erasing the whole flash first (the size check above already passed)
#   st-flash mass erase: ok
#   st-flash: 131072 bytes written and verified (attempt 2)
#   Verified OK
#   FLASH_OK 131072 bytes @ 0x8000000 backend stflash ...
```

With `STLINK_BACKEND=ocd` the same knob runs `stm32h7x mass_erase 0` after a
confirmed `reset halt`. Both paths record `whole flash (mass erase)` in
`erased but NOT written:` if the write afterwards fails, so a blank board is
never reported as "nothing was erased".

### Verdicts are measurements, not exit codes

Every tool on this fixture lies in a different direction, so the flash is read
back and *compared* before anything is claimed:

| Outcome | Meaning | Exit |
|---------|---------|------|
| `FLASH_OK …` | readback equals the image byte for byte | `0` |
| `FLASH_FAILED … partially written` | readback differs; the message says how many bytes of the image are present and where the first difference is | `3` |
| `FLASH_FAILED readback: …` | the flash could not be read back at all — its contents are **unknown**, which is not the same as wrong | `3` |

`st-flash` produced all three shapes on 2026-10-29/30: `131072/131072 bytes
written` followed by `ERROR common_flash.c: Flash programming error: 0x00040000`
(`PGSERR`) and `stlink_fwrite_flash() == -1`, an OpenOCD readback that died with
`Error: Failed to read memory at 0x0801d7c8`, and two dumps of the same range
that disagreed. Treating any of those as "the writer said yes" is how a blank
sector 0 gets reported as a successful flash.

Three checks now run **before anything is erased**:

1. **Sustained readback** (`STLINK_READBACK_PREFLIGHT`) — read 8 KiB twice and
   compare. A link that returns different bytes twice cannot carry a 4 KiB
   loader plus 128 KiB of image. Failure: exit 3, *nothing erased*.
2. **Loader RAM integrity** (`STLINK_RAM_INTEGRITY`) — `load_image` a 4 KiB
   random block into each of AXI SRAM / SRAM1 / SRAM4 / DTCM, `dump_image` it
   back and compare. Both writers execute code from RAM, so "RAM holds code" is
   a precondition, not a diagnostic. One good region is enough (it is reported);
   none ⇒ exit 2, nothing erased. `ram_usable`'s word probe alone once passed
   while the loader could not run — code-sized incompressible data is the honest
   test.
3. **Blank check** (`STLINK_BLANK_CHECK`) — after an erase, the range must read
   `0xFF` before a program is attempted. H7 raises `PGSERR` when a flash word is
   programmed without being erased, and then silently drops the rest of the
   write: `131072/131072 bytes written` with only ~1.4 KiB actually in the flash
   is exactly that.

### Erratum 3092511: a halt that never happened

A blank H7 halts into erratum 3092511, which OpenOCD reports as:

```text
halted due to debug-request, current mode: Thread
xPSR: 0x00000000 pc: 0x00000000 msp: 0x00000000
Error: unknown/unexpected STLINK status code 0x12
Error: Failed to write memory at 0x24000c00
```

`DHCSR` claims `S_HALT`, the register dump says `pc = msp = 0`, and every access
after it fails — including `load_image` and every loader download. The wrapper
rejects such a session (`FLASH_FAILED halt: … erratum 3092511`), retries with
fresh `reset halt`, and never converts its zeros into a RAM verdict.

The cure on a blank part is `STLINK_BACKEND=stflash`: `--connect-under-reset`
holds the core while it connects, which is the one attach that has ever worked
here. On the pad the sequence that mattered was: power-cycle, then
`st-flash --connect-under-reset …` immediately.

### Recovery: put sector 0 back

`tools/stlink_recover.sh` is the escalation when the normal flash path fails. It
tries three writers in the order that works on this fixture and validates the
result with a *different* tool than the one that wrote:

```bash
tools/stlink_recover.sh                          # default image
tools/stlink_recover.sh /tmp/bl_sector0.bin      # bootloader only, 0x08000000
tools/stlink_recover.sh image.bin 0x08020000     # app
tools/stlink_recover.sh --dry-run image.bin      # plan only, touch nothing
```

| Step | Tool | Notes |
|------|------|-------|
| 0 | OpenOCD `reset halt` + `reg pc` | no halt ⇒ advise, do not write (exit 5 if no `st-flash` either) |
| 1 | `st-flash --connect-under-reset write` | retried `STLINK_RECOVER_TRIES` (3) times, 2 s apart |
| 2 | `STM32_Programmer_CLI -c port=SWD mode=UR reset=SWrst -w … -v` | only if CubeProgrammer is installed |
| 3 | OpenOCD `program … verify` | last resort, one attempt, prints the failure signature |
| 4 | OpenOCD `verify_image` | the verdict: `RECOVER_OK`, or exit 4 on mismatch |
| 5 | OpenOCD `reset run` | else "power-cycle the pad" |

Exit codes: `0` written and verified, `1` usage, `2` no writer installed,
`3` every writer failed, `4` written but the readback disagrees, `5` no contact
and no `st-flash`. It never mass erases.

Keep the sector 0 image (`firmware/indi_h743/AP_Bootloader.bin`, or a copy of
`/tmp/bl_sector0.bin`) outside the pad: it is the one thing an erase cannot
bring back.

### The clone dongle

The ST-LINK on this fixture is a clone (`0483:3748`, FW `V2J46S7`,
`V2J46S7`-ish serials that read as binary garbage, e.g. `` `hÿ( ``, `µ[Z\x1a`).
Under load it re-enumerates:

```text
usb 1-1.3: reset full-speed USB device number 6 using xhci_hcd
usb 1-1.3: device firmware changed
```

Every unexplained artefact in this note correlates with those lines: `status
code 0x12`/`0x18`, 5.6 KiB/s dumps, `Failed to enter SWD mode`, the OpenOCD
loader dying mid-write, `st-flash` needing a retry. Mitigations, cheapest first:
shortest possible cable, direct Pi USB2 port (not the internal hub), powered
hub, or replace the dongle with a genuine ST-LINK/V3. `dmesg -T -w | grep -iE
"usb|stlink"` in a second terminal while flashing is the cheapest diagnostic
there is.

Do **not** rely on OpenOCD `reset` / `reset exit` for bring-up without NRST. After verify:

1. Optional soft start: `init; resume; exit` (or `reset run` — soft SYSRESETREQ only), **or**
2. **Preferred for pad test:** power-cycle via stepper jog (below).

### Status probe exit codes (suggested for Flask)

| Code | Meaning |
|------|---------|
| 0 | SWD up, target halted/examined |
| 2 | ST-LINK missing / OpenOCD cannot open adapter |
| 3 | Adapter up, VTarget present, SWD connect failed (contact / wiring / chip) |
| 4 | Flash/verify failed |
| 3 | SWD link lost, or core debug registers dead (AP) |
| 4 | Target would not halt / erase timed out (nothing erased) |
| 5 | No writable RAM for the flash loader (see above) |

Parse OpenOCD stderr for: `Target voltage`, `unable to connect`, `Verified OK`.

---

## 2. Combined bootloader + firmware image (IndiH743)

### No BL/app binaries on this Pi

Searched `/home/quality` — **no** ArduPilot tree, **no** `IndiH743` artifacts, **no** `*.apj`. Build artifacts live on the WSL machine.

### Assumed flash map (standard ArduPilot STM32H743)

Confirm on WSL before locking the applet:

```bash
grep -E 'FLASH_(SIZE|RESERVE_START|BOOTLOADER_LOAD)_KB|APP_START_OFFSET' \
  libraries/AP_HAL_ChibiOS/hwdef/IndiH743/hwdef*.dat
```

| Region | Address | Size | Source |
|--------|---------|------|--------|
| Bootloader | `0x08000000` | ≤ 128 KiB (sector 0) | `AP_Bootloader.bin` |
| Application | `0x08020000` | rest of flash | `arducopter.bin` (PadTest) |
| Gap `0x08000000+bl_len … 0x0801FFFF` | erase value `0xFF` | — | do not leave as `0x00` |

This matches typical H7 hwdef:

- `FLASH_BOOTLOADER_LOAD_KB 128` → app base `0x08000000 + 128*1024 = 0x08020000`
- `FLASH_RESERVE_START_KB 128` on the app hwdef (must agree)

**If IndiH743 uses a different `FLASH_BOOTLOADER_LOAD_KB`, change `APP_OFFSET` in the merge script — do not guess in the applet.**

### WSL input paths (expected)

| Artifact | Typical path |
|----------|----------------|
| Pad-test app `.bin` | `/home/bassam/ardupilot/build/IndiH743-PadTest/bin/arducopter.bin` |
| Bootloader `.bin` | `/home/bassam/ardupilot/build/IndiH743/bin/AP_Bootloader.bin` **or** `Tools/bootloaders/IndiH743_bl.bin` |
| Do **not** flash `.apj` raw | APJ is JSON+base64; unpack or use `.bin` |

### Merge on Pi (or WSL, then scp)

```bash
python3 /home/quality/stepper_controller/tools/merge_indi_h743_image.py \
  --bootloader /path/to/AP_Bootloader.bin \
  --firmware   /path/to/arducopter.bin \
  --out-bin    /home/quality/stepper_controller/firmware/indi_h743/combined.bin \
  --out-hex    /home/quality/stepper_controller/firmware/indi_h743/combined.hex
```

Defaults: `--flash-base 0x08000000 --app-offset 0x20000` (128 KiB).

**Fresh chip:** flash **`combined.bin` @ `0x08000000`** once.  
**App-only update** (BL already present): flash `arducopter.bin` @ `0x08020000` only — not the pad-test “virgin MCU” path.

H7 note: flash writes must stay 32-byte aligned; OpenOCD’s `stm32h7x` driver handles programming; keep merged image length sector-friendly (script pads with `0xFF`).

---

## 3. Flask applet implementation recipe

Base URL: `http://127.0.0.1:5000` (session cookie / same login as dashboard).  
Stepper serial device: `/dev/stepper_controller` (FIREPHX → `ttyACM0`).  
Existing motion routes (already in `server.py`):

- `GET /jog/forward` → Arduino `JOG 1` (toward **forward** limit — contact for H7)
- `GET /jog/backward` → Arduino `JOG -1` (toward **backward** limit — retract)
- `GET /status` → JSON including `state`, `position`, `homed`, limits
- Project **`H7`**: forward `67420`, backward `35000`

### (a) Status probe

1. Ensure project H7 loaded; axis at/near **forward** (contact). Poll `/status` until `state=="READY"` and `position` near forward limit.
2. Run:

```bash
/home/quality/stepper_controller/tools/stlink_probe.sh
```

Success criteria in log: STLINK line, `Target voltage: 3.x`, target examined / halted — **no** `unable to connect`.

### (b) Flash `.bin` or `.hex`

- Prefer the **combined** image for virgin MCUs (path under `firmware/indi_h743/`).
- The applet never talks to OpenOCD directly: it runs `tools/stlink_flash.sh <file>`,
  which chooses the writer (`st-flash`, see *Backend*), verifies the readback and
  prints `FLASH_OK ...` / `FLASH_FAILED ...`.
- Do **not** use `program <file> verify exit` - that is the OpenOCD write path
  that dies on this fixture.

Call `tools/stlink_flash.sh <file>` from a worker thread; stream stderr to the UI; never block the Flask process without a timeout (e.g. 120 s).

### (c) Optional run-after-program

```bash
/home/quality/stepper_controller/tools/stlink_run.sh
```

Uses soft resume/reset over SWD. Treat as best-effort.

### (d) Power-cycle via fixture (recommended after flash)

With H7 limits loaded and login session:

```http
GET /jog/backward
# wait until /status state READY (or timeout ~30s) — retract / break contact
GET /jog/forward
# wait until READY — re-seat / restore power through fixture
```

Then optionally re-run `(a)` probe or a UART check on `/dev/ttyUSB0` (CP2102 present, unused by current service).

### Suggested applet flow

```text
select H7 → HOME if needed → jog forward (contact)
→ stlink_probe
→ stlink_flash(combined)
→ [optional stlink_run] OR jog backward → wait → jog forward
→ report pass/fail + OpenOCD tail
```

---

## 4. Files dropped for the applet session

| Path | Purpose |
|------|---------|
| `docs/STLINK_FLASH_HANDOFF.md` | This handoff |
| `tools/merge_indi_h743_image.py` | BL + app → `combined.bin` / `.hex` |
| `tools/stlink_probe.sh` | Connect-only OpenOCD probe |
| `tools/stlink_flash.sh` | Program + verify (no hard reset dependency) |
| `tools/stlink_run.sh` | Soft resume after program |
| `tools/openocd_fixture.cfg` | Shared Tcl preamble (iface/transport/reset/target + AXI SRAM work area) |
| `tools/stlink_soak.sh` | Link-health soak (N connects; exit 1 when marginal) |
| `tests/stubs/openocd` | Fake OpenOCD; lets `tests/check_scripts.sh` exercise the flash wrapper and soak |
| `tests/test_stlink.py` | Classifier unit tests (DTCM fault + FLASH_OK logs) |
| `firmware/indi_h743/README.md` | Where to place BL / app / combined |

---

## 5. Open items for WSL owner

1. Confirm IndiH743 `FLASH_BOOTLOADER_LOAD_KB` (expect **128**).
2. Copy `AP_Bootloader.bin` + PadTest `arducopter.bin` onto the Pi under `firmware/indi_h743/`.
3. Run merge script; flash only after pogos are at **forward** contact and probe returns voltage + SWD OK.
4. Decide whether pad-test power is cut by retract (jog backward) — if not, soft `stlink_run` may be enough and jog is only mechanical unload.
