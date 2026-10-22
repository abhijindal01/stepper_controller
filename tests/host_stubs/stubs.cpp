/*
 * Definitions for the host-side Arduino stand-ins.
 * See tests/host_stubs/Arduino.h.
 */

#include "Arduino.h"
#include "EEPROM.h"


HardwareSerial Serial;

EEPROMClass EEPROM;


unsigned long millis()
{
    static unsigned long fakeTime = 0;

    fakeTime += 10;

    return fakeTime;
}


void delay(unsigned long ms)
{
    (void)ms;
}


void delayMicroseconds(unsigned long us)
{
    (void)us;
}


void pinMode(int pin, int mode)
{
    (void)pin;
    (void)mode;
}


void digitalWrite(int pin, int value)
{
    (void)pin;
    (void)value;
}


// Tests can drive the pins through this array.
// Default 0 (LOW) - set the idle/pressed levels you need before
// calling setup()/loop().

int g_pinState[64] = {0};


int digitalRead(int pin)
{
    if (pin >= 0 && pin < 64)
    {
        return g_pinState[pin];
    }

    return LOW;
}
