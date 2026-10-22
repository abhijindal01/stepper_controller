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

        digitalWrite(EN_PIN, LOW);
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

        digitalWrite(EN_PIN, LOW);
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

        digitalWrite(EN_PIN, LOW);
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

        digitalWrite(EN_PIN, LOW);
        state = READY;
        saveState(false);

        Serial.println("STOPPED");
        return;
    }

    // ===========================
    // EMERGENCY STOP
    // ===========================

    if (cmd == "ESTOP")
    {
        digitalWrite(EN_PIN, HIGH);
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

        digitalWrite(EN_PIN, LOW);
        long value = cmd.substring(3).toInt();
        jog(value);
        return;
    }

    // ===========================
    // UNKNOWN
    // ===========================

    Serial.println("UNKNOWN COMMAND");
}
