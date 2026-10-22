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
// STEP MOTOR
// ==================================================

void stepMotor(int speed)
{
    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(speed);
    digitalWrite(STEP_PIN, LOW);
    delayMicroseconds(speed);
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
