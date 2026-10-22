#ifndef CONFIG_H
#define CONFIG_H


// ================= STEPPER DRIVER =================

#define EN_PIN      7
#define DIR_PIN     8
#define STEP_PIN    9


// ================= HOME LIMIT SWITCH ==============

#define HOME_PIN    2
#define HOME_TRIGGER HIGH


// ================= EMERGENCY STOP =================

#define ESTOP_PIN   5
#define ESTOP_TRIGGER LOW


// ================= MANUAL TOGGLE ==================

#define FORWARD_SWITCH   3
#define BACKWARD_SWITCH  4


// ================= MOTOR DIRECTION =================

#define CLOCKWISE        HIGH
#define ANTICLOCKWISE    LOW


// ================= SPEED ===========================

#define FAST_HOME_SPEED     250
#define NORMAL_SPEED        600
#define SLOW_HOME_SPEED     1000


// ================= HOMING ==========================

#define HOME_OFFSET_STEPS   5000
#define HOME_WAIT_TIME      3000


// ================= EEPROM ==========================
// Limits block (compatible with v2.0.0 addresses)
#define EEPROM_FORWARD          10
#define EEPROM_BACKWARD         20
#define EEPROM_MAGIC            30
#define EEPROM_VALID            123

// Reboot state persistence block (position + homed flag)
#define EEPROM_POSITION         40
#define EEPROM_HOMED            48
#define EEPROM_STATE_MAGIC      52
#define EEPROM_STATE_VALID      0x53545032UL

// Auto-backup interval (ms) to protect AVR EEPROM endurance
#define POSITION_BACKUP_INTERVAL 1000UL


// ================= LIMITS ==========================
// Default / cleared travel limit steps (+/- 85,000, decreased from 2,000,000,000)

#define CLEAR_LIMIT_STEPS    85000L
#define NO_FORWARD_LIMIT     CLEAR_LIMIT_STEPS
#define NO_BACKWARD_LIMIT   (-CLEAR_LIMIT_STEPS)


// ================= SERIAL ==========================

#define SERIAL_SPEED 115200


// ================= FIRMWARE ========================

#define FIRMWARE_VERSION "2.1.0"


#endif
