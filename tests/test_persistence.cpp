/*
 * Host-side logic test for the firmware.
 *
 *   bash tests/check_firmware.sh
 *
 * It runs the REAL firmware sources against the stub Arduino core
 * (tests/host_stubs) and checks the two behaviours that are easy to get
 * silently wrong:
 *
 *   1. the position + homed flag survive a reboot (EEPROM restore)
 *   2. CLEAR LIMITS gives +/- CLEAR_LIMIT_STEPS (85000), not 2000000000
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


// defined by the stub core - lets us fake the switches
extern int g_pinState[64];


// prototypes the Arduino IDE would normally generate for us
void checkEmergencyStop();
void emergencyState();


// the sketch itself
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
    // INPUT_PULLUP wiring: everything idle is HIGH, active is LOW.
    for (int i = 0; i < 64; i++)
    {
        g_pinState[i] = HIGH;
    }

    // home limit switch pressed so the homing sequence can finish
    g_pinState[HOME_PIN] = HIGH;

    // emergency stop is triggered by LOW - keep it released
    g_pinState[ESTOP_PIN] = HIGH;

    // manual toggle switches released (active LOW)
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

    // Let the 1-second auto-backup interval expire. The host millis()
    // advances in short increments, just as time passes during motion.
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
    // CLEAR LIMITS -> +/- 85000
    // ================================================

    forwardLimit = 500;

    backwardLimit = -500;

    clearLimits();

    check(forwardLimit == 85000L, "clear limits -> forward = 85000");

    check(backwardLimit == -85000L, "clear limits -> backward = -85000");


    // ================================================
    // HOME COMMAND FORGETS THE STORED STATE
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
