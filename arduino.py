"""Legacy single-motor helper preserved for backwards compatibility.

New code uses steppers.py, which manages both hardcoded Arduinos:
    /dev/stepper_a -> Motor 1
    /dev/stepper_b -> Motor 2
"""

from steppers import BAUD_RATE as BAUD, MOTOR_1_PORT as PORT, MOTORS


def connect():
    return MOTORS["motor1"].connect(force=True)


def send(command):
    reply = MOTORS["motor1"].send(command)
    return reply if reply is not None else "Arduino not connected"


def status():
    return send("STATUS")
