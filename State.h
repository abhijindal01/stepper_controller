#ifndef STATE_H
#define STATE_H


enum MachineState
{

    FAST_HOMING,

    MOVE_OFFSET,

    WAITING,

    FINAL_HOMING,

    READY,


    MOVING_FORWARD,

    MOVING_BACKWARD,


    ESTOPPED

};
#endif