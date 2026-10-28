#include <Arduino.h>

#include "Config.h"
#include "State.h"
#include "Machine.h"
#include "Motion.h"


// ==================================================
// GLOBAL VARIABLES
// ==================================================

extern long currentPosition;
extern long forwardLimit;
extern long backwardLimit;
extern bool moving;
extern MachineState state;


// ==================================================
// STEPPER DRIVER POWER / THERMAL MANAGEMENT
// ==================================================
// A4988 / DRV8825 / TMC drivers keep the motor coils energised at full
// current for as long as EN_PIN is active. Holding that state while the
// machine is idle is what made the motor and driver slowly heat up.
// The coils are therefore released automatically a short time after the
// last step (IDLE_HOLD_MS) and re-energised on the next step.

static bool driverEnergised = false;
static bool holdOverride = false;
static unsigned long idleHoldMs = IDLE_HOLD_MS;
static unsigned long lastStepMs = 0;


// ==================================================
// ENERGISES THE DRIVER COILS
// ==================================================

void driverEnable()
{
    if (!driverEnergised)
    {
        digitalWrite(EN_PIN, EN_ACTIVE_LEVEL);

        // Give the driver time to come out of standby before the
        // first pulse, otherwise the first step can be lost.
        delayMicroseconds(ENABLE_SETTLE_US);

        driverEnergised = true;
    }

    lastStepMs = millis();
}


// ==================================================
// RELEASES THE DRIVER COILS (NO HOLDING CURRENT)
// ==================================================

void driverDisable()
{
    digitalWrite(EN_PIN, EN_INACTIVE_LEVEL);

    driverEnergised = false;
    lastStepMs = millis();
}


bool driverIsEnabled()
{
    return driverEnergised;
}


// ==================================================
// OPERATOR OVERRIDE: KEEP THE COILS ENERGISED
// ==================================================

void holdDriver(bool keepEnergised)
{
    holdOverride = keepEnergised;

    if (keepEnergised)
    {
        driverEnable();
        return;
    }

    // Release the override, then let the normal idle timeout expire
    lastStepMs = millis();
}


void setDriverIdleHold(unsigned long ms)
{
    if (ms > IDLE_HOLD_MS_MAX)
    {
        ms = IDLE_HOLD_MS_MAX;
    }

    idleHoldMs = ms;
    lastStepMs = millis();
}


unsigned long driverIdleHoldMs()
{
    return idleHoldMs;
}


unsigned long driverIdleMillis()
{
    return millis() - lastStepMs;
}


bool driverHoldOverride()
{
    return holdOverride;
}


// ==================================================
// IDLE WATCHDOG
// Called from loop() on every pass. Releases the coils once the axis
// has been still for the configured time so nothing keeps heating.
// Any step re-energises the driver straight away.
// ==================================================

void serviceDriverIdle()
{
    if (!driverEnergised || holdOverride || idleHoldMs == 0)
    {
        return;
    }

    // Never cut holding torque in the middle of a sequence: a loaded
    // axis could drop while homing or moving. Keep the timer fresh and
    // only start counting once the machine has settled in READY.
    if (state != READY)
    {
        lastStepMs = millis();
        return;
    }

    if (millis() - lastStepMs < idleHoldMs)
    {
        return;
    }

    driverDisable();

    Serial.println("DRIVER RELEASED (IDLE)");
}


// ==================================================
// STEP MOTOR
// ==================================================

void stepMotor(int speed)
{
    // Moving always re-energises the driver (no-op when already on)
    driverEnable();

    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(speed);
    digitalWrite(STEP_PIN, LOW);
    delayMicroseconds(speed);

    lastStepMs = millis();
}


// ==================================================
// SINGLE FORWARD STEP
// ==================================================

void moveForward()
{
    if (currentPosition >= forwardLimit)
    {
        Serial.println("FORWARD LIMIT REACHED");
        state = READY;
        saveState(false);
        return;
    }

    digitalWrite(DIR_PIN, ANTICLOCKWISE);
    stepMotor(NORMAL_SPEED);
    currentPosition++;
}


// ==================================================
// SINGLE BACKWARD STEP
// ==================================================

void moveBackward()
{
    if (currentPosition <= backwardLimit)
    {
        Serial.println("BACKWARD LIMIT REACHED");
        state = READY;
        saveState(false);
        return;
    }

    digitalWrite(DIR_PIN, CLOCKWISE);
    stepMotor(NORMAL_SPEED);
    currentPosition--;
}


// ==================================================
// CONTINUOUS FORWARD
// ==================================================

void moveForwardContinuous()
{
    if (currentPosition >= forwardLimit)
    {
        Serial.println("FORWARD LIMIT REACHED");
        state = READY;
        saveState(false);
        return;
    }

    moveForward();

    static unsigned long lastReport = 0;

    if (millis() - lastReport > 250)
    {
        Serial.print("MOVING_FORWARD POSITION:");
        Serial.println(currentPosition);
        lastReport = millis();
    }
}


// ==================================================
// CONTINUOUS BACKWARD
// ==================================================

void moveBackwardContinuous()
{
    if (currentPosition <= backwardLimit)
    {
        Serial.println("BACKWARD LIMIT REACHED");
        state = READY;
        saveState(false);
        return;
    }

    moveBackward();

    static unsigned long lastReport = 0;

    if (millis() - lastReport > 250)
    {
        Serial.print("MOVING_BACKWARD POSITION:");
        Serial.println(currentPosition);
        lastReport = millis();
    }
}


// ==================================================
// MANUAL TOGGLE SWITCH
// ==================================================

bool lastForwardSwitch = false;
bool lastBackwardSwitch = false;


void normalControl()
{
    bool forward = digitalRead(FORWARD_SWITCH) == LOW;
    bool backward = digitalRead(BACKWARD_SWITCH) == LOW;

    if (forward && backward)
    {
        Serial.println("BOTH SWITCHES ACTIVE");
        return;
    }

    if (forward && !lastForwardSwitch)
    {
        Serial.print("START FORWARD MOVE. STEPS:");
        Serial.println(forwardLimit - currentPosition);
        state = MOVING_FORWARD;
    }

    if (backward && !lastBackwardSwitch)
    {
        Serial.print("START BACKWARD MOVE. STEPS:");
        Serial.println(currentPosition - backwardLimit);
        state = MOVING_BACKWARD;
    }

    lastForwardSwitch = forward;
    lastBackwardSwitch = backward;
}


// ==================================================
// DASHBOARD JOG COMMAND
// JOG 1  = move toward forward limit
// JOG -1 = move toward backward limit
// ==================================================

void jog(long steps)
{
    if (steps > 0)
    {
        Serial.println("START MOVING FORWARD");
        state = MOVING_FORWARD;
    }
    else if (steps < 0)
    {
        Serial.println("START MOVING BACKWARD");
        state = MOVING_BACKWARD;
    }
}


// ==================================================
// MOVEMENT STATE HANDLER
// ==================================================

void updateMovement()
{
    switch (state)
    {
        case MOVING_FORWARD:
            moveForwardContinuous();
            break;

        case MOVING_BACKWARD:
            moveBackwardContinuous();
            break;

        default:
            moving = false;
            break;
    }
}
