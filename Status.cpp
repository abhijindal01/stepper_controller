#include <Arduino.h>

#include "Config.h"
#include "State.h"
#include "Status.h"


extern long currentPosition;

extern long forwardLimit;

extern long backwardLimit;

extern bool homed;

extern MachineState state;



void sendStatus()
{


Serial.print("{");



// =========================
// MACHINE STATE
// =========================


Serial.print("\"state\":\"");


switch(state)
{


case FAST_HOMING:

Serial.print("FIRST HOMING");

break;



case MOVE_OFFSET:

Serial.print("MOVING OFFSET");

break;



case WAITING:

Serial.print("WAITING");

break;



case FINAL_HOMING:

Serial.print("FINAL HOMING");

break;



case READY:

Serial.print("READY");

break;



case MOVING_FORWARD:

Serial.print("FORWARD");

break;



case MOVING_BACKWARD:

Serial.print("BACKWARD");

break;



case ESTOPPED:

Serial.print("EMERGENCY STOP");

break;



default:

Serial.print("UNKNOWN");

break;

}



Serial.print("\",");




// =========================
// POSITION
// =========================


Serial.print("\"position\":");

Serial.print(currentPosition);



Serial.print(",");




// =========================
// HOMED STATUS
// =========================


Serial.print("\"homed\":");


if(homed)
{
    Serial.print("true");
}
else
{
    Serial.print("false");
}



Serial.print(",");




// =========================
// LIMITS
// =========================


Serial.print("\"forward\":");

Serial.print(forwardLimit);



Serial.print(",");



Serial.print("\"backward\":");

Serial.print(backwardLimit);



Serial.print(",");





// =========================
// HOME SWITCH
// =========================


Serial.print("\"home_switch\":\"");


if(
digitalRead(HOME_PIN)==HOME_TRIGGER
)
{
    Serial.print("ON");
}
else
{
    Serial.print("OFF");
}


Serial.print("\",");




// =========================
// FORWARD TOGGLE
// =========================


Serial.print("\"forward_switch\":\"");


if(
digitalRead(FORWARD_SWITCH)==LOW
)
{
    Serial.print("ON");
}
else
{
    Serial.print("OFF");
}


Serial.print("\",");




// =========================
// BACKWARD TOGGLE
// =========================


Serial.print("\"backward_switch\":\"");


if(
digitalRead(BACKWARD_SWITCH)==LOW
)
{
    Serial.print("ON");
}
else
{
    Serial.print("OFF");
}


Serial.print("\",");




// =========================
// EMERGENCY STOP
// =========================


Serial.print("\"emergency\":\"");


if(
digitalRead(ESTOP_PIN)==ESTOP_TRIGGER
)
{
    Serial.print("ON");
}
else
{
    Serial.print("OFF");
}


Serial.println("\"}");



}