/*
 * Minimal host-side stand-ins for the Arduino core.
 *
 * They exist for ONE reason: to let
 *
 *     bash tests/check_firmware.sh
 *
 * syntax-check the firmware on a normal PC (no Arduino toolchain, no
 * board attached) so a typo is caught before it is uploaded.
 *
 * They are NOT uploaded to the board and are NOT part of the firmware.
 */

#ifndef ARDUINO_STUB_H
#define ARDUINO_STUB_H

#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <iostream>
#include <string>


#define HIGH 1
#define LOW  0

#define INPUT         0
#define OUTPUT        1
#define INPUT_PULLUP  2


typedef uint8_t byte;
typedef bool boolean;


unsigned long millis();

void delay(unsigned long ms);

void delayMicroseconds(unsigned long us);

void pinMode(int pin, int mode);

void digitalWrite(int pin, int value);

int digitalRead(int pin);


// ---------------------------------------------------------------
// String
// ---------------------------------------------------------------

class String : public std::string
{
public:

    String() {}

    String(const char* text) : std::string(text ? text : "") {}

    String(const std::string& text) : std::string(text) {}

    void trim()
    {
        const char* blanks = " \t\r\n";

        size_t first = find_first_not_of(blanks);

        if (first == npos)
        {
            clear();
            return;
        }

        size_t last = find_last_not_of(blanks);

        *this = substr(first, last - first + 1);
    }

    void toUpperCase()
    {
        for (size_t i = 0; i < size(); i++)
        {
            (*this)[i] = (char)toupper((unsigned char)(*this)[i]);
        }
    }

    bool startsWith(const char* other) const
    {
        return compare(0, strlen(other), other) == 0;
    }

    bool startsWith(const String& other) const
    {
        return compare(0, other.size(), other) == 0;
    }

    int indexOf(char needle, size_t from = 0) const
    {
        size_t found = find(needle, from);

        return found == npos ? -1 : (int)found;
    }

    String substring(size_t from) const
    {
        return String(substr(from));
    }

    String substring(size_t from, size_t to) const
    {
        return String(substr(from, to - from));
    }

    long toInt() const
    {
        return strtol(c_str(), NULL, 10);
    }
};


// ---------------------------------------------------------------
// Serial
// ---------------------------------------------------------------

struct HardwareSerial
{
    void begin(unsigned long speed)
    {
        (void)speed;
    }

    int available()
    {
        return 0;
    }

    String readStringUntil(char terminator)
    {
        (void)terminator;
        return String();
    }

    template <typename T>
    void print(const T& value)
    {
        std::cout << value;
    }

    template <typename T>
    void println(const T& value)
    {
        std::cout << value << std::endl;
    }

    void println()
    {
        std::cout << std::endl;
    }

    void flush() {}
};


extern HardwareSerial Serial;


#endif
