#include <Arduino.h>
#include <EEPROM.h>

#include "Config.h"
#include "Machine.h"


// Variables are created in StepperController.ino
extern long currentPosition;
extern long forwardLimit;
extern long backwardLimit;
extern bool homed;


static long lastSavedPosition = 0;
static bool lastSavedHomed = false;
static bool stateStoredValid = false;
static unsigned long lastBackupTime = 0;


// ==================================================
// WRITE CURRENT LIMITS TO EEPROM
// ==================================================

void saveLimitsToEEPROM()
{
    EEPROM.put(EEPROM_FORWARD, forwardLimit);
    EEPROM.put(EEPROM_BACKWARD, backwardLimit);

    byte valid = EEPROM_VALID;
    EEPROM.put(EEPROM_MAGIC, valid);
}


// ==================================================
// LOAD LIMITS & POSITION STATE FROM EEPROM
// ==================================================

void loadEEPROM()
{
    byte check = 0;
    EEPROM.get(EEPROM_MAGIC, check);

    if (check == EEPROM_VALID)
    {
        EEPROM.get(EEPROM_FORWARD, forwardLimit);
        EEPROM.get(EEPROM_BACKWARD, backwardLimit);

        // Migrate any legacy 2,000,000,000 unrestricted values down to 85,000
        if (forwardLimit > 100000000L)
        {
            forwardLimit = CLEAR_LIMIT_STEPS;
        }
        if (backwardLimit < -100000000L)
        {
            backwardLimit = -CLEAR_LIMIT_STEPS;
        }

        Serial.println("EEPROM LIMITS LOADED");
    }
    else
    {
        forwardLimit = NO_FORWARD_LIMIT;
        backwardLimit = NO_BACKWARD_LIMIT;

        Serial.println("NO LIMITS SAVED");
    }

    Serial.print("Forward Limit: ");
    Serial.println(forwardLimit);

    Serial.print("Backward Limit: ");
    Serial.println(backwardLimit);

    uint32_t stateMagic = 0;
    EEPROM.get(EEPROM_STATE_MAGIC, stateMagic);

    if (stateMagic == EEPROM_STATE_VALID)
    {
        long savedPos = 0;
        byte savedHomed = 0;

        EEPROM.get(EEPROM_POSITION, savedPos);
        EEPROM.get(EEPROM_HOMED, savedHomed);

        if (savedHomed == 1)
        {
            currentPosition = savedPos;
            homed = true;
            lastSavedPosition = currentPosition;
            lastSavedHomed = true;
            stateStoredValid = true;
            lastBackupTime = millis();

            Serial.print("EEPROM POSITION RESTORED: ");
            Serial.println(currentPosition);
            return;
        }
    }

    currentPosition = 0;
    homed = false;
    lastSavedPosition = 0;
    lastSavedHomed = false;
    stateStoredValid = false;
    lastBackupTime = millis();
}


// ==================================================
// SAVE FORWARD LIMIT
// ==================================================

void saveForwardLimit()
{
    forwardLimit = currentPosition;
    saveLimitsToEEPROM();

    Serial.print("FORWARD LIMIT SAVED: ");
    Serial.println(forwardLimit);
}


// ==================================================
// SAVE BACKWARD LIMIT
// ==================================================

void saveBackwardLimit()
{
    backwardLimit = currentPosition;
    saveLimitsToEEPROM();

    Serial.print("BACKWARD LIMIT SAVED: ");
    Serial.println(backwardLimit);
}


// ==================================================
// CLEAR LIMITS
// Resets forward/backward limits to +/- 85,000 steps
// and invalidates saved limit marker in EEPROM.
// ==================================================

void clearLimits()
{
    forwardLimit = CLEAR_LIMIT_STEPS;
    backwardLimit = -CLEAR_LIMIT_STEPS;

    byte invalid = 0;
    EEPROM.put(EEPROM_MAGIC, invalid);

    Serial.println("LIMITS CLEARED");
}


// ==================================================
// SAVE POSITION & HOMED FLAG TO EEPROM
// ==================================================

void saveState(bool verbose)
{
    if (!stateStoredValid || currentPosition != lastSavedPosition || homed != lastSavedHomed)
    {
        byte homedByte = homed ? 1 : 0;
        uint32_t magic = EEPROM_STATE_VALID;

        EEPROM.put(EEPROM_POSITION, currentPosition);
        EEPROM.put(EEPROM_HOMED, homedByte);
        EEPROM.put(EEPROM_STATE_MAGIC, magic);

        lastSavedPosition = currentPosition;
        lastSavedHomed = homed;
        stateStoredValid = true;
    }

    lastBackupTime = millis();

    if (verbose)
    {
        Serial.print("POSITION SAVED: ");
        Serial.println(currentPosition);
    }
}


// ==================================================
// WIPE SAVED POSITION / HOMED STATE
// Forces the board to re-home on next boot or HOME.
// ==================================================

void wipeState()
{
    homed = false;

    byte homedByte = 0;
    uint32_t invalidMagic = 0UL;

    EEPROM.put(EEPROM_HOMED, homedByte);
    EEPROM.put(EEPROM_STATE_MAGIC, invalidMagic);

    lastSavedHomed = false;
    stateStoredValid = false;
}


// ==================================================
// PERIODIC AUTO-BACKUP OF POSITION
// Rate-limited to once per second so EEPROM is never
// worn out during continuous stepping.
// ==================================================

void updatePositionBackup()
{
    unsigned long now = millis();

    if (!homed)
    {
        return;
    }

    if (now - lastBackupTime >= POSITION_BACKUP_INTERVAL)
    {
        lastBackupTime = now;

        if (!stateStoredValid || currentPosition != lastSavedPosition || homed != lastSavedHomed)
        {
            saveState(false);
        }
    }
}
