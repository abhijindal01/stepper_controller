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

Prefer the helper script:

```bash
/home/quality/stepper_controller/tools/stlink_flash.sh \
  /home/quality/stepper_controller/firmware/indi_h743/combined.bin
```

Equivalent one-liner:

```bash
openocd \
  -f interface/stlink.cfg \
  -c "transport select swd" \
  -c "adapter speed 1800" \
  -c "reset_config none" \
  -f target/stm32h7x.cfg \
  -c "program /ABS/PATH/combined.bin 0x08000000 verify exit"
```

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
| `tools/openocd_fixture.cfg` | Shared Tcl preamble (iface/transport/reset/target) |
| `firmware/indi_h743/README.md` | Where to place BL / app / combined |

---

## 5. Open items for WSL owner

1. Confirm IndiH743 `FLASH_BOOTLOADER_LOAD_KB` (expect **128**).
2. Copy `AP_Bootloader.bin` + PadTest `arducopter.bin` onto the Pi under `firmware/indi_h743/`.
3. Run merge script; flash only after pogos are at **forward** contact and probe returns voltage + SWD OK.
4. Decide whether pad-test power is cut by retract (jog backward) — if not, soft `stlink_run` may be enough and jog is only mechanical unload.
