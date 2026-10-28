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


// Tests can drive the INPUT pins through this array.
// Default 0 (LOW) - set the idle/pressed levels you need before
// calling setup()/loop().

int g_pinState[64] = {0};


// Output pins remember their mode and the level last written to them,
// so a test can prove what the firmware really drives - for example
// that the driver ENABLE pin is inactive while the machine idles.

int g_pinMode[64] = {INPUT};

int g_pinOutput[64] = {LOW};


void pinMode(int pin, int mode)
{
    if (pin >= 0 && pin < 64)
    {
        g_pinMode[pin] = mode;
    }
}


void digitalWrite(int pin, int value)
{
    if (pin >= 0 && pin < 64)
    {
        g_pinOutput[pin] = value ? HIGH : LOW;
    }
}


int digitalRead(int pin)
{
    if (pin < 0 || pin >= 64)
    {
        return LOW;
    }

    if (g_pinMode[pin] == OUTPUT)
    {
        return g_pinOutput[pin];
    }

    return g_pinState[pin];
}
