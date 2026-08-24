#include <Arduino.h>
#include <EEPROM.h>

#include "Config.h"
#include "Machine.h"
#include "State.h"

#include "Commands.h"
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

    // REMOVED:
    //   Serial.print("COMMAND RECEIVED: ");
    //   Serial.println(cmd);
    //
    // This used to print BEFORE every command's actual response. Your
    // server.py's send_command() returns the FIRST non-empty line it
    // reads back -- so it was always grabbing "COMMAND RECEIVED: STATUS"
    // (or HOME, STOP, etc.) instead of the real response line. For
    // STATUS specifically that meant json.loads() got a non-JSON string
    // and failed, producing exactly the "INVALID DATA" error you saw.
    // Every other command was silently returning the wrong text too.

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
        homed = false;
        state = FAST_HOMING;

        Serial.println("START HOME");
        return;
    }

    // ===========================
    // CONTINUOUS FORWARD
    // ===========================

    if (cmd == "FORWARD")
    {
        digitalWrite(EN_PIN, LOW);      // Enable driver
        state = MOVING_FORWARD;

        Serial.println("FORWARD START");

        return;
    }

    // ===========================
    // CONTINUOUS BACKWARD
    // ===========================

    if (cmd == "BACKWARD")
    {
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
        state = READY;

        Serial.println("STOPPED");

        return;
    }

    // ===========================
    // EMERGENCY STOP
    // ===========================

    if (cmd == "ESTOP")
    {
        digitalWrite(EN_PIN, HIGH);

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
    // CLEAR SAVED LIMITS
    // Resets forward/backward limits
    // back to unrestricted defaults
    // ===========================

    if (cmd == "CLEAR_LIMITS")
    {
        clearLimits();
        return;
    }

    // ===========================
    // LOAD PROJECT LIMITS
    // Example:
    // LOAD_LIMITS,32902,-5000
    // ===========================

    if (cmd.startsWith("LOAD_LIMITS"))
    {
        int c1 = cmd.indexOf(',');
        int c2 = cmd.indexOf(',', c1 + 1);

        forwardLimit = cmd.substring(c1 + 1, c2).toInt();
        backwardLimit = cmd.substring(c2 + 1).toInt();

        Serial.println("LIMITS LOADED");

        Serial.print("Forward=");
        Serial.println(forwardLimit);

        Serial.print("Backward=");
        Serial.println(backwardLimit);

        return;
    }

    // ===========================
    // JOG
    // ===========================

    if (cmd.startsWith("JOG"))
    {
        long value = cmd.substring(3).toInt();

        jog(value);

        return;
    }

    // ===========================
    // UNKNOWN
    // ===========================

    Serial.println("UNKNOWN COMMAND");
}
