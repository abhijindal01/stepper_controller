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
| `STLINK_RESET_HALT` | `1` | Halt out of reset before erasing (see below) |
| `STLINK_HALT_TRIES` | `4` | Halt attempts before giving up |
| `STLINK_RUN_AFTER` | `1` | `reset run` once the image verifies |
| `STLINK_OPENOCD_TIMEOUT` | `300` | Per-OpenOCD-session timeout (s) |
| `STLINK_FULL_VERIFY` | `1` | Second whole-image verify pass (`0` = per-sector only) |
| `STLINK_FLASH_TIMEOUT` | `1800` | Server-side (`stlink.py`) ceiling for the whole flash (s) |

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
| `target was in unknown state when halt was requested` | `halt` did not stop a running app | fixed: `reset halt` + DHCSR check |
| `erase time-out or operation error sector 0` | target reset itself mid-erase (IWDG/brownout) | re-seat, power-cycle the pad, retry (`STLINK_SPEED=25`) |
| `Fail reading CTRL/STAT register. Force reconnect` | SWD link lost (chip reset / contact) | re-seat contact, power-cycle |
| `init mode failed (unable to connect to the target)` | chip in fault/lockup loop, or no contact | run the manual recovery above |
| `no writable RAM for the flash loader` | no halt + no reachable RAM | re-seat, power-cycle, retry |

Exit codes / markers from the wrapper: `0` ok (`FLASH_OK ...`),
`1` usage or image-range error, `2` no writable work area (`FLASH_FAILED ram: ...`),
`3` flash/verify failed (`FLASH_FAILED erase|write|verify|swd: ...`),
`4` target could not be halted (`FLASH_FAILED halt: ...`, nothing erased).

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
| `tests/stubs/openocd` | Fake OpenOCD; lets `tests/check_scripts.sh` exercise the flash wrapper |
| `tests/test_stlink.py` | Classifier unit tests (DTCM fault + FLASH_OK logs) |
| `firmware/indi_h743/README.md` | Where to place BL / app / combined |

---

## 5. Open items for WSL owner

1. Confirm IndiH743 `FLASH_BOOTLOADER_LOAD_KB` (expect **128**).
2. Copy `AP_Bootloader.bin` + PadTest `arducopter.bin` onto the Pi under `firmware/indi_h743/`.
3. Run merge script; flash only after pogos are at **forward** contact and probe returns voltage + SWD OK.
4. Decide whether pad-test power is cut by retract (jog backward) — if not, soft `stlink_run` may be enough and jog is only mechanical unload.
