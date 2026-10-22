/*
 * Host-side stand-in for the Arduino EEPROM library.
 * See tests/host_stubs/Arduino.h.
 */

#ifndef EEPROM_STUB_H
#define EEPROM_STUB_H

#include <stdint.h>
#include <string.h>


struct EEPROMClass
{
    // Model the 1 KB EEPROM used by an Arduino Uno/Nano.
    uint8_t storage[1024];

    template <typename T>
    T& get(int address, T& value)
    {
        memcpy(&value, &storage[address], sizeof(T));
        return value;
    }

    template <typename T>
    void put(int address, const T& value)
    {
        memcpy(&storage[address], &value, sizeof(T));
    }

    int length() const
    {
        return sizeof(storage);
    }

    uint8_t read(int address)
    {
        return storage[address];
    }

    void write(int address, uint8_t value)
    {
        storage[address] = value;
    }

    void update(int address, uint8_t value)
    {
        storage[address] = value;
    }
};


extern EEPROMClass EEPROM;


#endif
