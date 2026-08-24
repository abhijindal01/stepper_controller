#include <Arduino.h>
#include <EEPROM.h>

#include "Config.h"
#include "Machine.h"


// Variables are created in StepperController.ino
// Only access them here

extern long currentPosition;

extern long forwardLimit;

extern long backwardLimit;



// ==================================================
// LOAD LIMITS FROM EEPROM
// ==================================================

void loadEEPROM()
{

    byte check;


    EEPROM.get(
        EEPROM_MAGIC,
        check
    );


    if(check == EEPROM_VALID)
    {


        EEPROM.get(
            EEPROM_FORWARD,
            forwardLimit
        );


        EEPROM.get(
            EEPROM_BACKWARD,
            backwardLimit
        );


        Serial.println(
        "EEPROM LIMITS LOADED"
        );


    }
    else
    {


        forwardLimit = NO_FORWARD_LIMIT;

        backwardLimit = NO_BACKWARD_LIMIT;


        Serial.println(
        "NO LIMITS SAVED"
        );


    }



    Serial.print(
    "Forward Limit: "
    );

    Serial.println(
    forwardLimit
    );



    Serial.print(
    "Backward Limit: "
    );

    Serial.println(
    backwardLimit
    );


}





// ==================================================
// SAVE FORWARD LIMIT
// ==================================================

void saveForwardLimit()
{


    forwardLimit = currentPosition;



    EEPROM.put(
        EEPROM_FORWARD,
        forwardLimit
    );


    EEPROM.put(
        EEPROM_MAGIC,
        EEPROM_VALID
    );



    Serial.print(
    "FORWARD LIMIT SAVED: "
    );


    Serial.println(
    forwardLimit
    );


}





// ==================================================
// SAVE BACKWARD LIMIT
// ==================================================

void saveBackwardLimit()
{


    backwardLimit = currentPosition;



    EEPROM.put(
        EEPROM_BACKWARD,
        backwardLimit
    );


    EEPROM.put(
        EEPROM_MAGIC,
        EEPROM_VALID
    );



    Serial.print(
    "BACKWARD LIMIT SAVED: "
    );


    Serial.println(
    backwardLimit
    );


}





// ==================================================
// CLEAR LIMITS
// Resets forward/backward limits back to the
// unrestricted defaults and invalidates the
// saved EEPROM values so they are not reloaded
// on next boot.
// ==================================================

void clearLimits()
{


    forwardLimit = NO_FORWARD_LIMIT;

    backwardLimit = NO_BACKWARD_LIMIT;



    byte invalid = 0;


    EEPROM.put(
        EEPROM_MAGIC,
        invalid
    );



    Serial.println(
    "LIMITS CLEARED"
    );


}
