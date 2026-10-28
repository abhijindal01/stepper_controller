#include <EEPROM.h>

#include "Config.h"
#include "State.h"
#include "Machine.h"

#include "Motion.h"
#include "Homing.h"
#include "Commands.h"
#include "Status.h"


// ===================================================
// MACHINE STATES
// ===================================================

MachineState state = FAST_HOMING;

// ===================================================
// MACHINE VARIABLES
// ===================================================

long currentPosition = 0;

long forwardLimit = NO_FORWARD_LIMIT;

long backwardLimit = NO_BACKWARD_LIMIT;

unsigned long waitStart = 0;

bool homed = false;

bool moving = false;


// ===================================================
// SETUP
// ===================================================

void setup()
{
    Serial.begin(SERIAL_SPEED);

    Serial.println();
    Serial.println("=================================");
    Serial.println("STEPPER CONTROLLER");
    Serial.print("Firmware : ");
    Serial.println(FIRMWARE_VERSION);
    Serial.println("=================================");

    pinMode(EN_PIN, OUTPUT);
    pinMode(DIR_PIN, OUTPUT);
    pinMode(STEP_PIN, OUTPUT);

    pinMode(HOME_PIN, INPUT_PULLUP);
    pinMode(ESTOP_PIN, INPUT_PULLUP);

    pinMode(FORWARD_SWITCH, INPUT_PULLUP);
    pinMode(BACKWARD_SWITCH, INPUT_PULLUP);

    // Keep the driver released at boot. The coils are energised on the
    // first step (homing or move), so an idle machine never sits at full
    // holding current and heats up.
    holdDriver(false);
    driverDisable();

    loadEEPROM();

    Serial.print("DRIVER IDLE RELEASE: ");
    Serial.print(driverIdleHoldMs());

    if (driverIdleHoldMs() == 0)
    {
        Serial.println(" ms (HOLDING - coils never released)");
    }
    else
    {
        Serial.println(" ms");
    }

    if (homed)
    {
        Serial.println("STATE RESTORED - READY");
        state = READY;
    }
    else
    {
        Serial.println("STARTING AUTOMATIC HOMING");
        resetHomingOffset();
        state = FAST_HOMING;
    }
}


// ===================================================
// MAIN LOOP
// ===================================================

void loop()
{
    checkEmergencyStop();

    processSerial();

    switch (state)
    {
        case FAST_HOMING:
            fastHome();
            break;

        case MOVE_OFFSET:
            moveOffset();
            break;

        case WAITING:
            waitHome();
            break;

        case FINAL_HOMING:
            finalHome();
            break;

        case READY:
            normalControl();
            break;

        case MOVING_FORWARD:
            moveForwardContinuous();
            break;

        case MOVING_BACKWARD:
            moveBackwardContinuous();
            break;

        case ESTOPPED:
            emergencyState();
            break;
    }

    serviceDriverIdle();

    updatePositionBackup();
}


// ===================================================
// SAFETY FRAMEWORK
// ===================================================

void checkEmergencyStop()
{
    if (digitalRead(ESTOP_PIN) == ESTOP_TRIGGER && state != ESTOPPED)
    {
        Serial.println("EMERGENCY STOP");

        holdDriver(false);
        driverDisable();

        saveState(false);

        state = ESTOPPED;
    }
}


void emergencyState()
{
    // Locked state while E-Stop is active
}
