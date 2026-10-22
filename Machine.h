#ifndef MACHINE_H
#define MACHINE_H


void loadEEPROM();

void saveLimitsToEEPROM();

void saveForwardLimit();

void saveBackwardLimit();

void clearLimits();

void saveState(bool verbose = false);

void wipeState();

void updatePositionBackup();


#endif
