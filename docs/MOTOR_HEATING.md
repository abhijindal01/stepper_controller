# Motor / driver heating — cause and fix (firmware 2.2.0)

## Symptom

The stepper motor (and often the driver heatsink) warms up slowly while the
machine is **not moving**, and keeps getting hotter the longer the controller
is left powered. Motion itself feels normal.

## Root cause

The driver enable pin (`EN_PIN`, D7) is **active LOW** on A4988 / DRV8825 /
TMC2208 / TMC2209 breakouts. In firmware 2.1.0 and earlier:

* `setup()` executed `digitalWrite(EN_PIN, LOW);` — coils energised at boot.
* Nothing ever switched them off again. Only the **E-STOP** did (`EN_PIN` HIGH).
* `STOP` actually re-energised the driver.
* The 3 s `WAITING` pause in the homing cycle also held the coils at
  full current.
* `stepMotor()` is a blocking `delayMicroseconds()` pair, so no idle logic
  could run between steps.

Result: the motor sat at **100 % holding current**, 24/7. At standstill there is
no air movement and no back-EMF, so the winding `I²R` loss plus the driver's
internal losses raise the temperature until the motor and driver reach their
thermal equilibrium — the "it heats after some time" behaviour.

## What changed in 2.2.0

| Area | Change |
|------|--------|
| `Config.h` | `EN_ACTIVE_LEVEL` / `EN_INACTIVE_LEVEL`, `IDLE_HOLD_MS` (1500 ms), `IDLE_HOLD_MS_MAX`, `ENABLE_SETTLE_US` |
| `Motion.cpp` | New driver power API: `driverEnable()`, `driverDisable()`, `driverIsEnabled()`, `holdDriver()`, `setDriverIdleHold()`, `serviceDriverIdle()` |
| `Motion.cpp` | `stepMotor()` re-energises the driver before the first pulse and refreshes the idle timer after every step |
| `StepperController.ino` | Boot leaves the coils **released**; `loop()` runs the idle watchdog; E-stop uses the new API |
| `Commands.cpp` | All direct `EN_PIN` writes replaced; `STOP` no longer forces the driver on; new `DRIVER_OFF`, `DRIVER_ON`, `SET_IDLE_MS` commands |
| `Status.cpp` | `STATUS` now reports `driver`, `hold`, `idle_ms`, `idle_hold_ms` |
| Web console | "Driver: ON/OFF" pill, *Release (Cool)* / *Hold Torque* buttons, idle-window hint |

### Behaviour

1. Power-on: coils **off** (no heat while the machine waits).
2. First step (homing or a move): driver energised after a short
   `ENABLE_SETTLE_US` delay so the first step is not lost.
3. Movement: idle timer refreshed on each step, controller stays energised.
   Torque is **never** cut mid-sequence — homing and moves keep the coils on,
   the countdown only runs while the machine is settled in `READY`.
4. Motion stops: coils hold for `IDLE_HOLD_MS` (default 1.5 s) after the
   machine returns to `READY`, then the watchdog releases them and prints
   `DRIVER RELEASED (IDLE)`.
5. E-stop: coils released immediately and stay released.
6. Commands never energise the coils by themselves — only a real step does.
   Pressing/holding a move against an end position (already on the limit)
   therefore leaves the driver released instead of baking at the stop.

> **Holding torque:** while released there is no holding torque. A horizontal
> lead-screw stage is normally fine. For a vertical/gantry axis that must hold
> itself, set `IDLE_HOLD_MS` to `0` in `Config.h` (old always-on behaviour) or
> send `DRIVER_ON` / press **Hold Torque**, and fix the heat with the current
> limit instead (see below).

## Tuning without reflashing

| Serial command | Effect |
|----------------|--------|
| `DRIVER_OFF` (alias `RELEASE`) | Release the coils immediately, cancel hold override |
| `DRIVER_ON` (alias `HOLD`) | Energise and keep energised while idle |
| `SET_IDLE_MS,<ms>` | Idle window before release, `0` = never release, max 600000 |

The server exposes `DRIVER_OFF` / `DRIVER_ON` as the `driver_off` / `driver_on`
actions, which the *Release (Cool)* and *Hold Torque* buttons call.

## Hardware checks if it still gets warm

The firmware fix removes **standing** current. If the motor is still hot after
moving for a while:

1. **Current limit (Vref)** — this is the biggest factor. On A4988 /
   DRV8825 / TMC220x boards, set `I_max` to ~60–70 % of the motor's rated
   phase current, e.g. for an A4988: `Vref = I_max × 8 × R_sense`
   (`R_sense` is usually 0.1 Ω). Re-check after a 10-minute run.
2. **Power supply voltage** — running a 24 V-rated driver at 12 V costs extra
   current for the same torque; excessive voltage raises driver losses.
3. **Microstepping / decay mode** — full step + fast decay runs hottest.
   Use at least 1/8 microstepping if the mechanics allow it.
4. **Wiring** — `EN` must go to the driver's `EN`, not to `GND` and not to the
   Arduino's `5V`. With the machine idle, measure `EN`: it should sit at
   `EN_INACTIVE_LEVEL` (HIGH ≈ 3–5 V) and only drop to LOW while stepping.
5. **Inverted enable** — a few boards (and opto-isolated inputs) enable on
   HIGH. If yours does, swap the two levels in `Config.h`:
   `EN_ACTIVE_LEVEL HIGH` / `EN_INACTIVE_LEVEL LOW`.
6. **Ventilation** — a fan across the driver heatsink is cheap insurance.

## Verifying the fix

```bash
bash tests/check_firmware.sh     # 74 host-side firmware checks
python3 tests/test_server.py     # Flask API checks
```

On the bench:

1. `STATUS` while idle → `"driver":"OFF"`, growing `"idle_ms"`.
2. Send `FORWARD`, wait for it to stop → `"driver":"ON"`, then `"OFF"` after
   `idle_hold_ms`.
3. Leave the machine powered and idle for 15 minutes — the motor should stay
   at ambient temperature (or close to it).
