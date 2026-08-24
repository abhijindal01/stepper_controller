#ifndef MOTION_H
#define MOTION_H


void stepMotor(int speed);


void moveForward();

void moveBackward();


void moveForwardContinuous();

void moveBackwardContinuous();


void jog(long steps);


void normalControl();


void updateMovement();


#endif