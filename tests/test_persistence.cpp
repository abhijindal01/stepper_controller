/*
 * Host-side logic test for the firmware.
 *
 *   bash tests/check_firmware.sh
 *
 * It runs the REAL firmware sources against the stub Arduino core
 * (tests/host_stubs) and checks:
 *
 *   1. Position, homed flag, and forward/backward limits survive a reboot
 *   2. CLEAR LIMITS gives +/- CLEAR_LIMIT_STEPS (85000), not 2000000000
 *   3. LOAD_LIMITS persists project limits across reboots
 *   4. Legacy 2000000000 EEPROM limits migrate down to +/- 85000
 *   5. SAVE_POSITION / RESET_STATE / HOME serial commands behave properly
 *   6. The driver is released when idle and re-energised on the next step
 *      (the motor-heating fix); torque is kept through homing/motion
 *   7. DRIVER_OFF / DRIVER_ON / SET_IDLE_MS and E-STOP release the coils
 *   8. The idle-release window survives a reboot (0 = hold torque forever)
 *
 * No hardware needed.
 */

#include <Arduino.h>
#include <EEPROM.h>

#include <sstream>
#include <string>

#include "Config.h"
#include "State.h"
#include "Machine.h"
#include "Motion.h"
#include "Homing.h"
#include "Commands.h"
#include "Status.h"


extern int g_pinState[64];
extern int g_pinOutput[64];

void checkEmergencyStop();
void emergencyState();

#include "../StepperController.ino"


static int failures = 0;
static int checks = 0;


void check(bool condition, const char* what)
{
    checks++;

    if (condition)
    {
        std::cout << "  PASS    " << what << std::endl;
    }
    else
    {
        failures++;
        std::cout << "  FAIL    " << what << std::endl;
    }
}


void idle_pins()
{
    for (int i = 0; i < 64; i++)
    {
        g_pinState[i] = HIGH;
    }

    g_pinState[HOME_PIN] = HIGH;
    g_pinState[ESTOP_PIN] = HIGH;
    g_pinState[FORWARD_SWITCH] = HIGH;
    g_pinState[BACKWARD_SWITCH] = HIGH;
}


void run_loops(int howMany)
{
    for (int i = 0; i < howMany; i++)
    {
        loop();
    }
}


// Advance the stubbed millis() by roughly `ms` while only running the
// idle watchdog, so a test can sit still without stepping the motor.

void idle_for_ms(unsigned long ms)
{
    for (unsigned long elapsed = 0; elapsed < ms; elapsed += 10)
    {
        serviceDriverIdle();
    }
}


// Minimal JSON syntax check. The web console parses the STATUS line
// with json.loads(), so a missing or doubled comma must fail here.

class JsonValidator
{
public:

    explicit JsonValidator(const std::string& text) : data(text), pos(0) {}

    bool valid()
    {
        skipSpace();

        if (!parseValue())
        {
            return false;
        }

        skipSpace();

        return pos == data.size();
    }

private:

    const std::string& data;

    size_t pos;


    void skipSpace()
    {
        while (pos < data.size())
        {
            char c = data[pos];

            if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
            {
                return;
            }

            pos++;
        }
    }


    bool literal(const char* word)
    {
        size_t length = strlen(word);

        if (data.compare(pos, length, word) != 0)
        {
            return false;
        }

        pos += length;

        return true;
    }


    bool parseString()
    {
        if (pos >= data.size() || data[pos] != '"')
        {
            return false;
        }

        pos++;

        while (pos < data.size())
        {
            char c = data[pos];

            if (c == '\\')
            {
                pos += 2;
                continue;
            }

            pos++;

            if (c == '"')
            {
                return true;
            }
        }

        return false;
    }


    bool parseNumber()
    {
        size_t start = pos;

        if (pos < data.size() && data[pos] == '-')
        {
            pos++;
        }

        while (pos < data.size() && isdigit((unsigned char)data[pos]))
        {
            pos++;
        }

        return pos != start;
    }


    bool parseObject()
    {
        pos++;  // '{'

        skipSpace();

        if (pos < data.size() && data[pos] == '}')
        {
            pos++;
            return true;
        }

        while (true)
        {
            skipSpace();

            if (!parseString())
            {
                return false;
            }

            skipSpace();

            if (pos >= data.size() || data[pos] != ':')
            {
                return false;
            }

            pos++;

            skipSpace();

            if (!parseValue())
            {
                return false;
            }

            skipSpace();

            if (pos < data.size() && data[pos] == ',')
            {
                pos++;
                continue;
            }

            if (pos < data.size() && data[pos] == '}')
            {
                pos++;
                return true;
            }

            return false;
        }
    }


    bool parseArray()
    {
        pos++;  // '['

        skipSpace();

        if (pos < data.size() && data[pos] == ']')
        {
            pos++;
            return true;
        }

        while (true)
        {
            skipSpace();

            if (!parseValue())
            {
                return false;
            }

            skipSpace();

            if (pos < data.size() && data[pos] == ',')
            {
                pos++;
                continue;
            }

            if (pos < data.size() && data[pos] == ']')
            {
                pos++;
                return true;
            }

            return false;
        }
    }


    bool parseValue()
    {
        if (pos >= data.size())
        {
            return false;
        }

        switch (data[pos])
        {
            case '{': return parseObject();
            case '[': return parseArray();
            case '"': return parseString();
            case 't': return literal("true");
            case 'f': return literal("false");
            case 'n': return literal("null");
            default:  return parseNumber();
        }
    }
};


// Capture the STATUS line the firmware would send over serial, so the
// JSON the web console parses can be validated here.

std::string capture_status()
{
    std::stringstream buffer;
    std::streambuf* previous = std::cout.rdbuf(buffer.rdbuf());

    sendStatus();

    std::cout.rdbuf(previous);

    std::string text = buffer.str();

    while (!text.empty() &&
           (text.back() == '\n' || text.back() == '\r' || text.back() == ' '))
    {
        text.pop_back();
    }

    return text;
}


int main()
{
    std::cout << std::endl;
    std::cout << "Firmware logic tests" << std::endl;
    std::cout << "--------------------" << std::endl;

    idle_pins();


    // ================================================
    // FIRST BOOT - nothing stored yet, so it must home
    // ================================================

    setup();

    check(state == FAST_HOMING, "first boot starts homing");
    check(forwardLimit == 85000L, "initial forward limit is 85000");
    check(backwardLimit == -85000L, "initial backward limit is -85000");
    check(!driverIsEnabled(), "first boot leaves the driver released");
    check(g_pinOutput[EN_PIN] == EN_INACTIVE_LEVEL, "EN pin is inactive at boot");

    run_loops(20000);

    check(state == READY, "homing finishes");
    check(homed == true, "homed flag set after homing");
    check(currentPosition == 0, "origin is 0 after homing");
    check(!driverIsEnabled(), "driver is released once homing settles");
    check(
        g_pinOutput[EN_PIN] == EN_INACTIVE_LEVEL,
        "EN pin is inactive while the machine sits idle"
    );


    // ================================================
    // MOVE, THEN LET THE AUTOMATIC BACKUP RUN
    // ================================================

    currentPosition = 45000;
    saveForwardLimit();
    currentPosition = -40000;
    saveBackwardLimit();

    currentPosition = 12345;

    run_loops(200);

    updatePositionBackup();


    // ================================================
    // REBOOT - power cut and back on
    // ================================================

    currentPosition = 0;
    homed = false;
    state = FAST_HOMING;

    setup();

    check(state == READY, "does NOT re-home after reboot");
    check(currentPosition == 12345, "position restored after reboot");
    check(!driverIsEnabled(), "a reboot into READY does not energise the coils");
    check(homed == true, "homed flag restored after reboot");
    check(forwardLimit == 45000, "forward limit restored after reboot");
    check(backwardLimit == -40000, "backward limit restored after reboot");


    // ================================================
    // LOAD_LIMITS SERIAL COMMAND PERSISTS ACROSS REBOOT
    // ================================================

    Serial.feed("LOAD_LIMITS,64560,50000");
    loop();

    check(forwardLimit == 64560L, "LOAD_LIMITS sets forward limit");
    check(backwardLimit == 50000L, "LOAD_LIMITS sets backward limit");

    forwardLimit = 0;
    backwardLimit = 0;
    setup();

    check(forwardLimit == 64560L, "LOAD_LIMITS forward limit survives reboot");
    check(backwardLimit == 50000L, "LOAD_LIMITS backward limit survives reboot");


    // ================================================
    // CLEAR LIMITS -> +/- 85000 (AND SURVIVES REBOOT)
    // ================================================

    Serial.feed("CLEAR_LIMITS");
    loop();

    check(forwardLimit == 85000L, "clear limits -> forward = 85000");
    check(backwardLimit == -85000L, "clear limits -> backward = -85000");

    forwardLimit = 999;
    backwardLimit = -999;
    setup();

    check(forwardLimit == 85000L, "cleared forward limit = 85000 after reboot");
    check(backwardLimit == -85000L, "cleared backward limit = -85000 after reboot");


    // ================================================
    // LEGACY 2,000,000,000 EEPROM MIGRATION -> 85,000
    // ================================================

    long legacyFwd = 2000000000L;
    long legacyBwd = -2000000000L;
    byte validByte = EEPROM_VALID;
    EEPROM.put(EEPROM_FORWARD, legacyFwd);
    EEPROM.put(EEPROM_BACKWARD, legacyBwd);
    EEPROM.put(EEPROM_MAGIC, validByte);

    setup();

    check(forwardLimit == 85000L, "legacy 2000000000 forward clamped to 85000");
    check(backwardLimit == -85000L, "legacy -2000000000 backward clamped to -85000");


    // ================================================
    // HOME / RESET_STATE WIPES THE STORED STATE
    // ================================================

    currentPosition = 999;
    saveState(false);

    wipeState();
    setup();

    check(homed == false, "wipeState clears the homed flag");
    check(state == FAST_HOMING, "board homes again after the state is wiped");

    run_loops(20000);

    check(currentPosition == 0 && homed, "re-homes to 0");


    // ================================================
    // DRIVER HEATING PROTECTION (the whole point of 2.2.0)
    // ================================================

    // Stepping always energises the coils
    driverDisable();
    stepMotor(NORMAL_SPEED);

    check(driverIsEnabled(), "stepping energises the driver");
    check(g_pinOutput[EN_PIN] == EN_ACTIVE_LEVEL, "EN pin is active while stepping");

    // ... and stays energised for short pauses
    idle_for_ms(IDLE_HOLD_MS / 2);
    check(driverIsEnabled(), "driver stays energised during a short pause");

    // ... but is released once the axis has been idle long enough,
    // which is what stops the motor and driver from heating up.
    idle_for_ms(IDLE_HOLD_MS + 300);
    check(!driverIsEnabled(), "driver auto-releases after IDLE_HOLD_MS");
    check(
        g_pinOutput[EN_PIN] == EN_INACTIVE_LEVEL,
        "EN pin returns to inactive after the idle release"
    );

    // HOLD (DRIVER_ON) keeps the coils energised for as long as needed
    holdDriver(true);
    idle_for_ms(IDLE_HOLD_MS * 4);
    check(driverIsEnabled(), "HOLD keeps the driver energised past the timeout");
    check(driverHoldOverride(), "hold override is reported");

    holdDriver(false);
    idle_for_ms(IDLE_HOLD_MS + 300);
    check(!driverIsEnabled(), "dropping the hold lets the driver cool again");

    // Runtime-configurable idle window
    setDriverIdleHold(4000);
    driverEnable();
    idle_for_ms(IDLE_HOLD_MS + 500);
    check(driverIsEnabled(), "a longer idle window delays the release");
    idle_for_ms(3000);
    check(!driverIsEnabled(), "the driver still releases eventually");

    // 0 restores the old always-energised behaviour
    setDriverIdleHold(0);
    driverEnable();
    idle_for_ms(30000);
    check(driverIsEnabled(), "idle window 0 keeps the coils energised");
    setDriverIdleHold(IDLE_HOLD_MS);

    // Torque must not be cut mid-sequence, but must be released once
    // homing has settled back into READY.
    driverEnable();
    state = WAITING;
    waitStart = millis();
    idle_for_ms(IDLE_HOLD_MS * 3);
    check(driverIsEnabled(), "driver stays energised during the homing wait");

    run_loops(600);
    check(state == READY, "homing completes after the wait");

    idle_for_ms(IDLE_HOLD_MS + 300);
    check(!driverIsEnabled(), "driver is released once homing settles");


    // ================================================
    // DRIVER / THERMAL SERIAL COMMANDS
    // ================================================

    driverEnable();
    Serial.feed("DRIVER_OFF");
    loop();
    check(!driverIsEnabled(), "DRIVER_OFF releases the coils immediately");

    Serial.feed("DRIVER_ON");
    loop();
    check(driverIsEnabled(), "DRIVER_ON energises the coils");
    check(driverHoldOverride(), "DRIVER_ON holds the coils while idle");

    Serial.feed("SET_IDLE_MS,4000");
    loop();
    check(driverIdleHoldMs() == 4000, "SET_IDLE_MS applies the new idle window");

    Serial.feed("SET_IDLE_MS,abc");
    loop();
    check(driverIdleHoldMs() == 0, "SET_IDLE_MS clamps garbage to 0");

    Serial.feed("SET_IDLE_MS,1500");
    loop();
    check(driverIdleHoldMs() == IDLE_HOLD_MS, "SET_IDLE_MS restores the default");

    // A vice-like hold must survive moves and stops, otherwise a vertical
    // axis would drop 1.5 s after the move finishes.
    Serial.feed("JOG 1");
    loop();
    check(driverHoldOverride(), "a move keeps an operator hold override");

    Serial.feed("STOP");
    loop();
    check(
        driverHoldOverride() && driverIsEnabled(),
        "STOP keeps an operator hold override energised"
    );

    Serial.feed("DRIVER_OFF");
    loop();
    check(!driverIsEnabled() && !driverHoldOverride(), "DRIVER_OFF clears the hold");

    // This is the reported "hot once it reaches the position" case: the
    // axis is already on the limit, so a move command cannot step and
    // must not re-energise the coils.
    currentPosition = forwardLimit;
    Serial.feed("JOG 1");
    loop();
    check(!driverIsEnabled(), "a jog against the limit leaves the coils released");
    check(state == READY, "the axis stays READY when it is already on the limit");

    Serial.feed("FORWARD");
    loop();
    check(!driverIsEnabled(), "FORWARD at the limit leaves the coils released");

    // ... while a move that really steps still energises them
    currentPosition = 0;
    Serial.feed("JOG 1");
    loop();
    check(driverIsEnabled(), "a jog that can move energises the coils");
    check(currentPosition == 1, "the jog actually stepped one step");

    Serial.feed("STOP");
    loop();
    driverDisable();

    // Physical toggle held down while the axis already sits on the limit
    currentPosition = forwardLimit;
    g_pinState[FORWARD_SWITCH] = LOW;
    loop();
    loop();
    check(!driverIsEnabled(), "the manual switch at the limit leaves the coils released");
    check(state == READY, "the manual switch does not restart a blocked move");

    g_pinState[FORWARD_SWITCH] = HIGH;
    loop();
    currentPosition = 0;


    // ================================================
    // E-STOP ALWAYS WINS
    // ================================================

    driverEnable();
    g_pinState[ESTOP_PIN] = ESTOP_TRIGGER;
    loop();

    check(state == ESTOPPED, "hardware E-stop latches ESTOPPED");
    check(!driverIsEnabled(), "E-stop releases the driver coils");
    check(
        g_pinOutput[EN_PIN] == EN_INACTIVE_LEVEL,
        "EN pin is inactive while E-stopped"
    );

    Serial.feed("DRIVER_ON");
    loop();
    check(!driverIsEnabled(), "DRIVER_ON is refused while E-stop is active");

    g_pinState[ESTOP_PIN] = HIGH;
    Serial.feed("HOME");
    loop();
    check(state != ESTOPPED, "HOME clears the E-stopped condition");

    run_loops(20000);
    check(state == READY, "re-homes after the E-stop is cleared");


    // ================================================
    // THE IDLE-RELEASE WINDOW SURVIVES A REBOOT
    // (so "hold torque" is not lost on a board reset)
    // ================================================

    check(driverIdleHoldMs() == IDLE_HOLD_MS, "default window before saving");

    Serial.feed("SET_IDLE_MS,0");
    loop();
    check(driverIdleHoldMs() == 0, "SET_IDLE_MS,0 disables the release");

    setup();
    check(driverIdleHoldMs() == 0, "never-release survives a reboot");
    check(!driverIsEnabled(), "a reboot never energises the coils by itself");

    idle_for_ms(IDLE_HOLD_MS * 4);
    check(!driverIsEnabled(), "a released board stays released after reboot");

    Serial.feed("SET_IDLE_MS,1500");
    loop();
    check(driverIdleHoldMs() == IDLE_HOLD_MS, "restoring the auto-release window");

    setup();
    check(driverIdleHoldMs() == IDLE_HOLD_MS, "auto-release survives a reboot");


    // ================================================
    // STATUS JSON STAYS PARSEABLE FOR THE WEB CONSOLE
    // ================================================

    std::string statusJson = capture_status();

    check(
        !statusJson.empty() && statusJson.front() == '{' && statusJson.back() == '}',
        "STATUS emits one JSON object"
    );
    check(JsonValidator(statusJson).valid(), "STATUS is valid JSON");
    check(
        statusJson.find("\"driver\":\"") != std::string::npos,
        "STATUS reports the driver state"
    );
    check(
        statusJson.find("\"hold\":") != std::string::npos,
        "STATUS reports the hold override"
    );
    check(
        statusJson.find("\"idle_ms\":") != std::string::npos,
        "STATUS reports the idle time"
    );
    check(
        statusJson.find("\"idle_hold_ms\":") != std::string::npos,
        "STATUS reports the idle window"
    );
    check(
        statusJson.find("\"driver\":\"OFF\"") != std::string::npos,
        "STATUS shows the released driver when idle"
    );

    holdDriver(true);
    check(
        capture_status().find("\"driver\":\"ON\"") != std::string::npos,
        "STATUS shows the energised driver while holding"
    );
    holdDriver(false);
    driverDisable();

    int braceBalance = 0;

    for (char c : statusJson)
    {
        if (c == '{') braceBalance++;
        else if (c == '}') braceBalance--;
    }

    check(braceBalance == 0, "STATUS has balanced braces");


    // ================================================

    std::cout << "--------------------" << std::endl;
    std::cout << checks << " checks, " << failures << " failure(s)" << std::endl;

    return failures == 0 ? 0 : 1;
}
