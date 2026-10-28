#ifndef MOTION_H
#define MOTION_H


// ==================================================
// STEPPER DRIVER POWER CONTROL
// ==================================================

void driverEnable();

void driverDisable();

bool driverIsEnabled();

bool driverHoldOverride();

void holdDriver(bool keepEnergised);

void setDriverIdleHold(unsigned long ms);

unsigned long driverIdleHoldMs();

unsigned long driverIdleMillis();

void serviceDriverIdle();


void stepMotor(int speed);


void moveForward();

void moveBackward();


void moveForwardContinuous();

void moveBackwardContinuous();


void jog(long steps);


void normalControl();


void updateMovement();


#endif
