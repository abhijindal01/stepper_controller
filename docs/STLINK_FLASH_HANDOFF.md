# ST-LINK pad-test flash handoff (Pi fixture → Flask applet)

**Host:** `assurance` (RPi 4B) · Flask on `:5000` · ST-LINK/V2 `0483:3748` FW **V2J46S7**  
**OpenOCD:** `/usr/bin/openocd` `0.12.0+rpt…` (no CubeProgrammer / `st-flash` installed)  
**No NRST** on pogo harness — only SWCLK, SWDIO, GND (+ VTarget sense).

This note is the contract for the Flask ST-LINK applet session.

---

## 1. OpenOCD connect / flash recipe (proven on this Pi)

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

It erases + writes one 128 KiB sector per OpenOCD session and verifies each
sector plus the whole image. Do **not** use `program ... verify exit`: on this
H7 + ST-LINK/V2 combo it fails mid multi-sector erase/algo load.

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

Two explanations, both must be ruled out before flashing:

- the MCU really is a 1 MiB H743 (`xG`) or a relabelled H750 - ArduCopter does
  not fit, the hwdef needs `FLASH_SIZE_KB 1024` and a trimmed build;
- the probe read the wrong value (a flaky link can corrupt the `FLASHSIZE`
  register read at `0x1FF1E880`) - re-probe at 50 kHz on a clean link with
  `openocd -f tools/openocd_fixture.cfg -c "init; flash probe 0; exit"`.

`0x08000000`..`0x0801FFFF` (the bootloader sector) is the same either way, so a
sector-0-only write still fits and is enough to make the board bootable again.

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

- Prefer **combined** image for virgin MCUs (path under `firmware/indi_h743/`).
- `.bin` → `program <file> 0x08000000 verify exit`
- `.hex` → `program <file> verify exit` (addresses inside HEX)

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
