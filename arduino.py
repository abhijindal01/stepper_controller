import serial
import time


PORT="/dev/stepper_controller"

BAUD=115200


arduino=None



def connect():

    global arduino


    try:

        arduino=serial.Serial(
            PORT,
            BAUD,
            timeout=1
        )

        time.sleep(2)

        print("Arduino connected")


    except Exception as e:

        print("Arduino connection failed",e)

        arduino=None





def send(command):

    global arduino


    if arduino is None:
        connect()


    if arduino:


        arduino.write(
            (command+"\n").encode()
        )


        time.sleep(0.1)


        return arduino.readline().decode()


    return "Arduino not connected"





def status():

    return send("STATUS")
