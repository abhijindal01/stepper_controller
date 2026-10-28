#ifndef MACHINE_H
#define MACHINE_H


void loadEEPROM();

void saveLimitsToEEPROM();

void saveForwardLimit();

void saveBackwardLimit();

void clearLimits();

void saveState(bool verbose = false);

void saveIdleHoldToEEPROM(unsigned long ms);

void wipeState();

void updatePositionBackup();


#endif
