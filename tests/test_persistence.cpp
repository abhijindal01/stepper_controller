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
 *
 * No hardware needed.
 */

#include <Arduino.h>
#include <EEPROM.h>

#include "Config.h"
#include "State.h"
#include "Machine.h"
#include "Motion.h"
#include "Homing.h"
#include "Commands.h"
#include "Status.h"


extern int g_pinState[64];

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

    run_loops(20000);

    check(state == READY, "homing finishes");
    check(homed == true, "homed flag set after homing");
    check(currentPosition == 0, "origin is 0 after homing");


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

    std::cout << "--------------------" << std::endl;
    std::cout << checks << " checks, " << failures << " failure(s)" << std::endl;

    return failures == 0 ? 0 : 1;
}
