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

#define EEPROM_FORWARD      10
#define EEPROM_BACKWARD     20
#define EEPROM_MAGIC        30

#define EEPROM_VALID        123



// ================= LIMITS ===========================

#define NO_FORWARD_LIMIT    65000
#define NO_BACKWARD_LIMIT  -65000



// ================= SERIAL ==========================

#define SERIAL_SPEED 115200



// ================= FIRMWARE ========================

#define FIRMWARE_VERSION "2.0.0"


#endif
