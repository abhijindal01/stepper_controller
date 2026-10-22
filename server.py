"""
Stepper Controller web server (Raspberry Pi).

ONE Raspberry Pi, TWO Arduinos, TWO stepper motors.

    /dev/stepper_a  ->  MOTOR 1
    /dev/stepper_b  ->  MOTOR 2

The ports are hardcoded in steppers.py - see the comments there and
udev/99-stepper-controllers.rules for how the stable names are created.

Each motor has its OWN independent project list (saved forward/backward
limits) and its own controls on the dashboard.
"""

from flask import Flask, render_template, request, jsonify, redirect, url_for, session, abort
from functools import wraps

import json
import os
import secrets

from steppers import MOTORS, MOTOR_IDS, get_motor, connect_all


app = Flask(__name__)


# ==========================
# LOGIN CONFIG
# ==========================
# Set APP_PASSWORD / APP_SECRET_KEY as environment variables in
# production instead of relying on the defaults below.

APP_PASSWORD = os.environ.get("APP_PASSWORD", "atol@a616")

app.secret_key = os.environ.get("APP_SECRET_KEY", secrets.token_hex(16))


PROJECT_FILE = os.environ.get("PROJECT_FILE", "projects.json")


# ==========================
# ARDUINO SERIAL
# ==========================
# Both boards are opened here. If a board is not plugged in yet the
# Motor object keeps retrying (rate limited) whenever a command is sent,
# so the Pi does not have to be restarted after reconnecting a cable.

connect_all()


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
# projects.json now keeps ONE SEPARATE LIST PER MOTOR:
#
#   {
#     "motor1": { "H7": {"forward": 54753, "backward": 35000}, ... },
#     "motor2": { "H7": {"forward": 12000, "backward": -500},  ... }
#   }
#
# The old flat format ({ "H7": {...} } with no motor key) is migrated
# automatically the first time it is loaded - old projects become
# MOTOR 1 projects.


def empty_project_store():

    return {motor_id: {} for motor_id in MOTOR_IDS}



def looks_like_project(value):

    return (
        isinstance(value, dict)
        and "forward" in value
        and "backward" in value
    )



def load_all_projects():

    if not os.path.exists(PROJECT_FILE):

        return empty_project_store()


    with open(PROJECT_FILE, "r") as f:

        try:
            data = json.load(f)
        except ValueError:
            return empty_project_store()


    if not isinstance(data, dict):
        return empty_project_store()


    # ---- legacy flat file -> migrate to per-motor ----

    legacy = {
        name: value
        for name, value in data.items()
        if looks_like_project(value)
    }

    if legacy:

        data = empty_project_store()

        data["motor1"] = legacy

        save_all_projects(data)

        print("Migrated %d project(s) to MOTOR 1" % len(legacy))

        return data


    # ---- current format: make sure every motor has a list ----

    store = empty_project_store()

    for motor_id in MOTOR_IDS:

        projects = data.get(motor_id, {})

        if isinstance(projects, dict):
            store[motor_id] = projects

    return store



def save_all_projects(data):

    with open(PROJECT_FILE, "w") as f:

        json.dump(
            data,
            f,
            indent=4
        )



def load_projects(motor_id):

    return load_all_projects().get(motor_id, {})



def save_projects(motor_id, projects):

    data = load_all_projects()

    data[motor_id] = projects

    save_all_projects(data)



# ==========================
# JSON HELPERS
# ==========================


def motor_or_404(motor_id):

    motor = get_motor(motor_id)

    if motor is None:
        abort(404)

    return motor



def command_response(motor, command, reply):

    return jsonify(
        {
            "ok": reply is not None,
            "motor": motor.id,
            "port": motor.port,
            "command": command,
            "response": reply,
            "connected": motor.connected,
            "error": None if reply is not None else (motor.last_error or "NO RESPONSE"),
        }
    )



# ==========================
# DASHBOARD
# ==========================


@app.route("/")
@login_required
def index():

    return render_template(
        "index.html",
        motors=[MOTORS[motor_id].info() for motor_id in MOTOR_IDS],
        projects=load_all_projects()
    )



# ==========================
# MOTOR LIST / CONNECTION
# ==========================


@app.route("/api/motors")
@login_required
def api_motors():

    return jsonify(
        [MOTORS[motor_id].info() for motor_id in MOTOR_IDS]
    )



@app.route("/api/motor/<motor_id>/connect", methods=["POST"])
@login_required
def motor_connect(motor_id):

    motor = motor_or_404(motor_id)

    motor.disconnect()

    motor.connect()

    return jsonify(motor.info())



# ==========================
# MOTOR STATUS
# ==========================


@app.route("/api/motor/<motor_id>/status")
@login_required
def motor_status(motor_id):

    motor = motor_or_404(motor_id)

    status = motor.status()

    if status is None:

        return jsonify(
            {
                "error": "NO RESPONSE",
                "connected": motor.connected,
                "port": motor.port,
                "message": motor.last_error or "Arduino not connected",
            }
        )

    status["connected"] = True

    status["port"] = motor.port

    return jsonify(status)



@app.route("/api/motor/<motor_id>/position")
@login_required
def motor_position(motor_id):

    motor = motor_or_404(motor_id)

    return jsonify(
        {
            "position": motor.position()
        }
    )



# ==========================
# MOTOR ACTIONS
# ==========================
# Every entry maps a short dashboard action name onto the command the
# Arduino firmware understands.

ACTIONS = {

    "home":          "HOME",
    "stop":          "STOP",
    "estop":         "ESTOP",

    "move_forward":  "FORWARD",
    "move_backward": "BACKWARD",

    "jog_forward":   "JOG 1",
    "jog_backward":  "JOG -1",

    "save_forward":  "SAVE_FORWARD",
    "save_backward": "SAVE_BACKWARD",
    "clear_limits":  "CLEAR_LIMITS",

    "save_position": "SAVE_POSITION",
    "reset_state":   "RESET_STATE",

}



@app.route("/api/motor/<motor_id>/action/<action_name>", methods=["POST"])
@login_required
def motor_action(motor_id, action_name):

    motor = motor_or_404(motor_id)

    if action_name not in ACTIONS:

        return jsonify(
            {
                "ok": False,
                "error": "UNKNOWN ACTION",
            }
        ), 404


    command = ACTIONS[action_name]

    reply = motor.send(command)

    return command_response(motor, command, reply)



# Raw passthrough, handy from the browser console / curl:
#   curl -X POST -d '{"command":"JOG 1"}' ...

@app.route("/api/motor/<motor_id>/command", methods=["POST"])
@login_required
def motor_command(motor_id):

    motor = motor_or_404(motor_id)

    data = request.json or {}

    command = str(data.get("command", "")).strip()

    if not command:

        return jsonify(
            {
                "ok": False,
                "error": "MISSING COMMAND",
            }
        ), 400


    reply = motor.send(command)

    return command_response(motor, command, reply)



# ==========================
# PROJECTS (per motor)
# ==========================


@app.route("/api/motor/<motor_id>/projects")
@login_required
def motor_projects(motor_id):

    motor_or_404(motor_id)

    return jsonify(load_projects(motor_id))



@app.route("/api/motor/<motor_id>/projects", methods=["POST"])
@login_required
def add_project(motor_id):

    motor = motor_or_404(motor_id)

    data = request.json

    if not data:

        return jsonify(
            {
                "ok": False,
                "error": "MISSING REQUEST DATA"
            }
        ), 400


    name = str(data.get("name", "")).strip()

    if not name:

        return jsonify(
            {
                "ok": False,
                "error": "PROJECT NAME IS REQUIRED"
            }
        ), 400


    # forward/backward arrive from the browser as strings (even from a
    # number input) and can be "" when the field is left blank.
    # int("") raises ValueError - validate first and answer with a
    # normal error instead of a 500.

    try:

        forward_val = int(data.get("forward", ""))

        backward_val = int(data.get("backward", ""))

    except (ValueError, TypeError):

        return jsonify(
            {
                "ok": False,
                "error": "FORWARD AND BACKWARD LIMITS MUST BE WHOLE NUMBERS (NOT BLANK)"
            }
        ), 400


    projects = load_projects(motor_id)

    projects[name] = {
        "forward": forward_val,
        "backward": backward_val
    }

    save_projects(motor_id, projects)

    return jsonify(
        {
            "ok": True,
            "message": "PROJECT SAVED",
            "motor": motor.id,
            "project": projects[name]
        }
    )



@app.route("/api/motor/<motor_id>/projects/<name>/load", methods=["POST"])
@login_required
def select_project(motor_id, name):

    motor = motor_or_404(motor_id)

    projects = load_projects(motor_id)

    if name not in projects:

        return jsonify(
            {
                "ok": False,
                "error": "PROJECT NOT FOUND"
            }
        ), 404


    project = projects[name]

    command = "LOAD_LIMITS,%d,%d" % (
        project["forward"],
        project["backward"]
    )

    reply = motor.send(command)

    result = command_response(motor, command, reply).get_json()

    result["project"] = name

    return jsonify(result)



@app.route("/api/motor/<motor_id>/projects/<name>", methods=["DELETE"])
@login_required
def delete_project(motor_id, name):

    motor_or_404(motor_id)

    projects = load_projects(motor_id)

    if name not in projects:

        return jsonify(
            {
                "ok": False,
                "error": "PROJECT NOT FOUND"
            }
        ), 404


    del projects[name]

    save_projects(motor_id, projects)

    return jsonify(
        {
            "ok": True,
            "message": "PROJECT DELETED"
        }
    )



# ==========================
# RUN
# ==========================


if __name__ == "__main__":

    app.run(
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "5000")),
        debug=os.environ.get("FLASK_DEBUG", "0") == "1"
    )
