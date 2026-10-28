#include <Arduino.h>
#include <EEPROM.h>

#include "Config.h"
#include "Machine.h"
#include "State.h"

#include "Commands.h"
#include "Homing.h"
#include "Status.h"
#include "Motion.h"

extern long currentPosition;
extern long forwardLimit;
extern long backwardLimit;

extern bool homed;
extern bool moving;
extern MachineState state;


void processSerial()
{
    if (!Serial.available())
        return;

    String cmd = Serial.readStringUntil('\n');

    cmd.trim();
    cmd.toUpperCase();

    if (cmd == "")
        return;

    // ===========================
    // STATUS
    // ===========================

    if (cmd == "STATUS")
    {
        sendStatus();
        return;
    }

    // ===========================
    // POSITION
    // ===========================

    if (cmd == "GET_POSITION")
    {
        Serial.print("POSITION:");
        Serial.println(currentPosition);
        return;
    }

    // ===========================
    // HOME
    // ===========================

    if (cmd == "HOME")
    {
        if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER)
        {
            Serial.println("EMERGENCY STOP ACTIVE");
            return;
        }

        // The first homing step energises the coils; any operator
        // hold-torque override stays in place.
        wipeState();
        resetHomingOffset();
        state = FAST_HOMING;

        Serial.println("START HOME");
        return;
    }

    // ===========================
    // CONTINUOUS FORWARD
    // ===========================

    if (cmd == "FORWARD")
    {
        if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER)
        {
            Serial.println("EMERGENCY STOP ACTIVE");
            return;
        }

        state = MOVING_FORWARD;

        Serial.println("FORWARD START");
        return;
    }

    // ===========================
    // CONTINUOUS BACKWARD
    // ===========================

    if (cmd == "BACKWARD")
    {
        if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER)
        {
            Serial.println("EMERGENCY STOP ACTIVE");
            return;
        }

        state = MOVING_BACKWARD;

        Serial.println("BACKWARD START");
        return;
    }

    // ===========================
    // NORMAL STOP
    // ===========================

    if (cmd == "STOP")
    {
        if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER)
        {
            Serial.println("EMERGENCY STOP ACTIVE");
            return;
        }

        // Stop moving but keep the coils energised for the normal hold
        // window. They are released automatically once idle, so the
        // motor cannot sit at full holding current and cook.
        // A deliberate HOLD override survives a STOP.
        state = READY;
        moving = false;
        saveState(false);

        Serial.println("STOPPED");
        return;
    }

    // ===========================
    // EMERGENCY STOP
    // ===========================

    if (cmd == "ESTOP")
    {
        holdDriver(false);
        driverDisable();
        saveState(false);
        state = ESTOPPED;

        Serial.println("EMERGENCY STOP");
        return;
    }

    // ===========================
    // SAVE CURRENT POSITION
    // AS FORWARD LIMIT
    // ===========================

    if (cmd == "SAVE_FORWARD")
    {
        saveForwardLimit();
        return;
    }

    // ===========================
    // SAVE CURRENT POSITION
    // AS BACKWARD LIMIT
    // ===========================

    if (cmd == "SAVE_BACKWARD")
    {
        saveBackwardLimit();
        return;
    }

    // ===========================
    // CLEAR SAVED LIMITS (+/- 85,000)
    // ===========================

    if (cmd == "CLEAR_LIMITS")
    {
        clearLimits();
        return;
    }

    // ===========================
    // PERSIST CURRENT POSITION NOW
    // ===========================

    if (cmd == "SAVE_POSITION")
    {
        saveState(true);
        return;
    }

    // ===========================
    // WIPE SAVED STATE (FORCE RE-HOME ON BOOT)
    // ===========================

    if (cmd == "RESET_STATE")
    {
        wipeState();
        Serial.println("STATE RESET");
        return;
    }

    // ===========================
    // DRIVER COILS OFF (COOL DOWN NOW)
    // ===========================

    if (cmd == "DRIVER_OFF" || cmd == "RELEASE")
    {
        holdDriver(false);
        driverDisable();

        Serial.println("DRIVER OFF");
        return;
    }

    // ===========================
    // DRIVER COILS ON (HOLD TORQUE)
    // Keeps the motor energised while idle, e.g. for a vertical axis.
    // This intentionally disables the idle heat protection until the
    // next move, DRIVER_OFF or E-STOP.
    // ===========================

    if (cmd == "DRIVER_ON" || cmd == "HOLD")
    {
        if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER || state == ESTOPPED)
        {
            Serial.println("EMERGENCY STOP ACTIVE");
            return;
        }

        holdDriver(true);

        Serial.println("DRIVER ON");
        return;
    }

    // ===========================
    // SET IDLE RELEASE TIME (PERSISTED IN EEPROM)
    // Example: SET_IDLE_MS,3000  (0 = never release)
    // Survives a reboot, so a hold-torque setup is not lost when the
    // board resets (USB re-enumeration, power blip).
    // ===========================

    if (cmd.startsWith("SET_IDLE_MS"))
    {
        int c1 = cmd.indexOf(',');

        if (c1 < 0)
        {
            Serial.println("ERROR: INVALID SET_IDLE_MS FORMAT");
            return;
        }

        long value = cmd.substring(c1 + 1).toInt();

        if (value < 0)
        {
            value = 0;
        }

        setDriverIdleHold((unsigned long)value);
        saveIdleHoldToEEPROM(driverIdleHoldMs());

        Serial.print("IDLE_MS:");
        Serial.println(driverIdleHoldMs());
        return;
    }

    // ===========================
    // LOAD PROJECT LIMITS
    // Example: LOAD_LIMITS,32902,-5000
    // ===========================

    if (cmd.startsWith("LOAD_LIMITS"))
    {
        int c1 = cmd.indexOf(',');
        int c2 = cmd.indexOf(',', c1 + 1);

        if (c1 < 0 || c2 < 0)
        {
            Serial.println("ERROR: INVALID LOAD_LIMITS FORMAT");
            return;
        }

        forwardLimit = cmd.substring(c1 + 1, c2).toInt();
        backwardLimit = cmd.substring(c2 + 1).toInt();

        saveLimitsToEEPROM();

        Serial.print("LIMITS LOADED: Forward=");
        Serial.print(forwardLimit);
        Serial.print(", Backward=");
        Serial.println(backwardLimit);
        return;
    }

    // ===========================
    // JOG
    // ===========================

    if (cmd.startsWith("JOG"))
    {
        if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER)
        {
            Serial.println("EMERGENCY STOP ACTIVE");
            return;
        }

        // No driverEnable() here: if the axis already sits on the limit
        // no step happens, and the coils must stay released (no heat).
        long value = cmd.substring(3).toInt();
        jog(value);
        return;
    }

    // ===========================
    // UNKNOWN
    // ===========================

    Serial.println("UNKNOWN COMMAND");
}
