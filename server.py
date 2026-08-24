from flask import Flask, render_template, request, jsonify, redirect, url_for, session
from functools import wraps
import json
import os
import secrets
import serial
import time
import threading


app = Flask(__name__)


# ==========================
# LOGIN CONFIG
# ==========================
# Set APP_PASSWORD / APP_SECRET_KEY as environment variables in
# production instead of relying on the defaults below.

APP_PASSWORD = os.environ.get("APP_PASSWORD", "atol@a616")

app.secret_key = os.environ.get("APP_SECRET_KEY", secrets.token_hex(16))


PROJECT_FILE = "projects.json"

serial_lock = threading.Lock()


# ==========================
# ARDUINO SERIAL
# ==========================

try:

    arduino = serial.Serial(
        "/dev/stepper_controller",
        115200,
        timeout=1
    )

    time.sleep(2)

    arduino.reset_input_buffer()

    print("Arduino Connected")


except Exception as e:

    arduino = None

    print("Arduino Not Connected")
    print(e)



# ==========================
# LOGIN REQUIRED DECORATOR
# ==========================


def login_required(f):

    @wraps(f)
    def wrapped(*args, **kwargs):

        if not session.get("logged_in"):

            return redirect(url_for("login"))

        return f(*args, **kwargs)

    return wrapped



# ==========================
# LOGIN / LOGOUT
# ==========================


@app.route("/login", methods=["GET", "POST"])
def login():

    error = None

    if request.method == "POST":

        password = request.form.get("password", "")

        if password == APP_PASSWORD:

            session["logged_in"] = True

            return redirect(url_for("index"))

        else:

            error = "Incorrect password"

    return render_template(
        "login.html",
        error=error
    )



@app.route("/logout")
def logout():

    session.pop("logged_in", None)

    return redirect(url_for("login"))



# ==========================
# PROJECT HANDLING
# ==========================


def load_projects():

    if not os.path.exists(PROJECT_FILE):

        return {}

    with open(PROJECT_FILE,"r") as f:

        return json.load(f)



def save_projects(data):

    with open(PROJECT_FILE,"w") as f:

        json.dump(
            data,
            f,
            indent=4
        )



# ==========================
# SEND COMMAND
# ==========================


def send_command(cmd):

    if arduino is None:

        return None


    try:

        with serial_lock:


            print("SEND:",cmd)


            # remove old messages
            arduino.reset_input_buffer()


            arduino.write(
                (cmd+"\n").encode()
            )

            arduino.flush()


            start=time.time()


            while time.time()-start < 5:


                if arduino.in_waiting:


                    line = arduino.readline().decode(
                        errors="ignore"
                    ).strip()


                    print("ARDUINO:",line)


                    if line:

                        return line



            print("NO RESPONSE")

            return None



    except Exception as e:

        print("SERIAL ERROR:",e)

        return None




# ==========================
# DASHBOARD
# ==========================


@app.route("/")
@login_required
def index():

    return render_template(
        "index.html",
        projects=load_projects()
    )



# ==========================
# ADD PROJECT
# ==========================


@app.route("/add_project",methods=["POST"])
@login_required
def add_project():

    data = request.json

    if not data:

        return "MISSING REQUEST DATA", 400


    name = data.get("name", "").strip()

    if not name:

        return "PROJECT NAME IS REQUIRED", 400


    # forward/backward come from the browser as strings (even from a
    # number input, JS sends them as text) -- and can be "" if the user
    # left the field blank. int("") crashes with an unhandled ValueError,
    # which is exactly what was producing the 500 error. Validate first
    # and return a normal error response instead of letting it crash.

    try:

        forward_val = int(data.get("forward", ""))

        backward_val = int(data.get("backward", ""))


    except (ValueError, TypeError):

        return "FORWARD AND BACKWARD LIMITS MUST BE WHOLE NUMBERS (NOT BLANK)", 400


    projects = load_projects()


    projects[name] = {

        "forward": forward_val,

        "backward": backward_val

    }


    save_projects(projects)


    return "PROJECT SAVED"




# ==========================
# SELECT PROJECT
# ==========================


@app.route("/select_project",methods=["POST"])
@login_required
def select_project():

    data=request.json

    name=data["name"]


    projects=load_projects()


    if name not in projects:

        return "PROJECT NOT FOUND"



    p=projects[name]


    result = send_command(
        f"LOAD_LIMITS,{p['forward']},{p['backward']}"
    )

    return result if result else "NO RESPONSE"




# ==========================
# DELETE PROJECT
# ==========================


@app.route("/delete_project/<name>")
@login_required
def delete_project(name):

    projects=load_projects()


    if name in projects:

        del projects[name]

        save_projects(projects)

        return "PROJECT DELETED"


    return "PROJECT NOT FOUND"




# ==========================
# STATUS
# ==========================


@app.route("/status")
@login_required
def status():


    result=send_command("STATUS")


    if result:


        try:

            return jsonify(
                json.loads(result)
            )


        except:


            return jsonify(
                {
                    "error":"INVALID DATA",
                    "raw":result
                }
            )


    return jsonify(
        {
            "error":"NO RESPONSE"
        }
    )




# ==========================
# POSITION
# ==========================


@app.route("/position")
@login_required
def position():

    result=send_command(
        "GET_POSITION"
    )

    return jsonify(
        {
            "position":result
        }
    )




# ==========================
# HOME
# ==========================


@app.route("/home")
@login_required
def home():

    result = send_command(
        "HOME"
    )

    return result if result else "NO RESPONSE"




# ==========================
# STOP
# ==========================


@app.route("/stop")
@login_required
def stop():

    result = send_command(
        "STOP"
    )

    return result if result else "NO RESPONSE"




# ==========================
# CONTINUOUS MOVE
# Used for "hold to move" jog control,
# e.g. while setting a limit by hand.
# ==========================


@app.route("/move/forward")
@login_required
def move_forward():

    result = send_command(
        "FORWARD"
    )

    return result if result else "NO RESPONSE"



@app.route("/move/backward")
@login_required
def move_backward():

    result = send_command(
        "BACKWARD"
    )

    return result if result else "NO RESPONSE"




# ==========================
# SAVE LIMITS
# ==========================


@app.route("/save_forward")
@login_required
def save_forward():

    result = send_command(
        "SAVE_FORWARD"
    )

    return result if result else "NO RESPONSE"



@app.route("/save_backward")
@login_required
def save_backward():

    result = send_command(
        "SAVE_BACKWARD"
    )

    return result if result else "NO RESPONSE"




# ==========================
# CLEAR LIMITS
# ==========================


@app.route("/clear_limits")
@login_required
def clear_limits():

    result = send_command(
        "CLEAR_LIMITS"
    )

    return result if result else "NO RESPONSE"




# ==========================
# JOG CONTROL
# ==========================


@app.route("/jog/forward")
@login_required
def jog_forward():


    result = send_command(
        "JOG 1"
    )

    return result if result else "NO RESPONSE"




@app.route("/jog/backward")
@login_required
def jog_backward():


    result = send_command(
        "JOG -1"
    )

    return result if result else "NO RESPONSE"





# ==========================
# RUN
# ==========================


if __name__=="__main__":


    app.run(
        host="0.0.0.0",
        port=5000
    )
