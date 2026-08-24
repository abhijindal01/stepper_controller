#include <Arduino.h>

#include "Config.h"
#include "State.h"
#include "Homing.h"
#include "Motion.h"



extern long currentPosition;

extern unsigned long waitStart;

extern bool homed;

extern MachineState state;



// ==================================================
// FAST HOMING
// ==================================================

void fastHome()
{


    digitalWrite(
        DIR_PIN,
        CLOCKWISE
    );



    // Home switch reached

    if(
      digitalRead(HOME_PIN)==HOME_TRIGGER
    )
    {


        Serial.println(
        "FIRST HOME FOUND"
        );



        state = MOVE_OFFSET;


        return;

    }



    stepMotor(
        FAST_HOME_SPEED
    );


}



// ==================================================
// MOVE AWAY FROM SWITCH
// ==================================================

void moveOffset()
{


    digitalWrite(
        DIR_PIN,
        ANTICLOCKWISE
    );



    static long offsetSteps = 0;



    if(offsetSteps < HOME_OFFSET_STEPS)
    {


        stepMotor(
            NORMAL_SPEED
        );


        offsetSteps++;


        return;


    }



    offsetSteps=0;



    waitStart = millis();



    Serial.println(
    "OFFSET COMPLETE"
    );



    state = WAITING;


}




// ==================================================
// WAIT BEFORE FINAL HOME
// ==================================================

void waitHome()
{


    if(
       millis()-waitStart >= HOME_WAIT_TIME
    )
    {


        Serial.println(
        "FINAL HOMING"
        );



        state = FINAL_HOMING;


    }


}




// ==================================================
// FINAL SLOW HOMING
// ==================================================

void finalHome()
{


    digitalWrite(
        DIR_PIN,
        CLOCKWISE
    );



    if(
      digitalRead(HOME_PIN)==HOME_TRIGGER
    )
    {


        currentPosition = 0;



        homed = true;



        Serial.println(
        "ORIGIN SET"
        );


        Serial.println(
        "READY"
        );



        state = READY;



        return;

    }



    stepMotor(
        SLOW_HOME_SPEED
    );

}