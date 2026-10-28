"""
Stepper Controller Web Console (Raspberry Pi).

ONE Raspberry Pi, TWO Arduinos, TWO stepper motors:

    /dev/stepper_a  ->  MOTOR 1
    /dev/stepper_b  ->  MOTOR 2

The ports are hardcoded in steppers.py and pinned via
udev/99-stepper-controllers.rules so they never swap across reboots.

Each motor has its own independent project preset list, customizable
purpose label, live telemetry, motion/limit controls, and EEPROM state
persistence across Arduino reboots.
"""

from __future__ import annotations

from functools import wraps
import json
import os
import secrets
import threading
import time
from typing import Any

from flask import (
    Flask,
    abort,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

import stlink
from steppers import MOTOR_IDS, MOTORS, connect_all, get_motor


app = Flask(__name__)

# ==========================
# LOGIN & APP CONFIG
# ==========================
# Set APP_PASSWORD / APP_SECRET_KEY in deploy/stepper-web.env in production.

APP_PASSWORD = os.environ.get("APP_PASSWORD", "atol@a616")
app.secret_key = os.environ.get("APP_SECRET_KEY", secrets.token_hex(32))

PROJECT_FILE = os.environ.get("PROJECT_FILE", "projects.json")
STLINK_DEFAULT_MOTOR = os.environ.get("STLINK_MOTOR", "motor1")
CLEAR_LIMIT_STEPS = 85000

_store_lock = threading.Lock()


@app.after_request
def _adapt_cookie_for_https_proxy(response):
    """Allow session cookie in HTTPS reverse-proxied contexts while keeping HTTP LAN intact."""
    is_https = (
        request.is_secure
        or request.headers.get("X-Forwarded-Proto", "").lower() == "https"
    )
    if is_https and "Set-Cookie" in response.headers:
        updated = []
        for cookie in response.headers.getlist("Set-Cookie"):
            if cookie.startswith("session="):
                parts = [
                    p.strip()
                    for p in cookie.split(";")
                    if not p.strip().lower().startswith("samesite=")
                    and p.strip().lower() != "secure"
                ]
                parts.extend(["SameSite=None", "Secure"])
                cookie = "; ".join(parts)
            updated.append(cookie)
        response.headers.setlist("Set-Cookie", updated)
    return response


# ==========================
# INITIAL ARDUINO CONNECT
# ==========================

if os.environ.get("SKIP_INITIAL_CONNECT", "0") != "1":
    connect_all()


# ==========================
# AUTHENTICATION
# ==========================


def login_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            if request.path.startswith("/api/") or request.path.startswith("/stlink/"):
                return jsonify({"ok": False, "error": "UNAUTHORIZED"}), 401
            return redirect(url_for("login"))
        return f(*args, **kwargs)

    return wrapped


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None

    if request.method == "POST":
        password = request.form.get("password", "")
        if password == APP_PASSWORD:
            session["logged_in"] = True
            return redirect(url_for("index"))
        error = "Incorrect password. Please try again."

    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.pop("logged_in", None)
    return redirect(url_for("login"))


# ==========================
# PROJECT & METADATA STORE
# ==========================
# Structure of projects.json:
# {
#   "motor1": { "H7": {"forward": 64560, "backward": 50000}, ... },
#   "motor2": { "ESC": {"forward": 78000, "backward": 70000}, ... },
#   "_meta": {
#     "motor1": {"purpose": "H7 Pad-Test Fixture", "active_project": null},
#     "motor2": {"purpose": "ESC Test Fixture", "active_project": null}
#   }
# }


def _default_meta() -> dict[str, dict[str, Any]]:
    return {
        mid: {
            "purpose": MOTORS[mid].default_purpose,
            "active_project": None,
        }
        for mid in MOTOR_IDS
    }


def _empty_store() -> dict[str, Any]:
    store: dict[str, Any] = {mid: {} for mid in MOTOR_IDS}
    store["_meta"] = _default_meta()
    return store


def _looks_like_project(value: Any) -> bool:
    return isinstance(value, dict) and "forward" in value and "backward" in value


def _load_raw_store_unlocked() -> dict[str, Any]:
    if not os.path.exists(PROJECT_FILE):
        return _empty_store()

    try:
        with open(PROJECT_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (ValueError, OSError):
        return _empty_store()

    if not isinstance(data, dict):
        return _empty_store()

    # Migrate legacy flat format ({"H7": {...}, "ESC": {"axis": "2", ...}})
    legacy_entries = {
        name: value
        for name, value in data.items()
        if name not in MOTOR_IDS and name != "_meta" and _looks_like_project(value)
    }

    if legacy_entries and not any(isinstance(data.get(mid), dict) for mid in MOTOR_IDS):
        migrated = _empty_store()
        for name, value in legacy_entries.items():
            axis_hint = str(value.get("axis", "1")).strip().lower()
            target_motor = (
                "motor2" if axis_hint in ("2", "motor2", "b") else "motor1"
            )
            migrated[target_motor][name] = {
                "forward": int(value["forward"]),
                "backward": int(value["backward"]),
            }
        _save_raw_store_unlocked(migrated)
        return migrated

    store = _empty_store()
    for mid in MOTOR_IDS:
        projects = data.get(mid, {})
        if isinstance(projects, dict):
            cleaned: dict[str, dict[str, int]] = {}
            for name, pval in projects.items():
                if _looks_like_project(pval):
                    try:
                        cleaned[name] = {
                            "forward": int(pval["forward"]),
                            "backward": int(pval["backward"]),
                        }
                    except (ValueError, TypeError):
                        continue
            store[mid] = cleaned

    raw_meta = data.get("_meta", {})
    if isinstance(raw_meta, dict):
        for mid in MOTOR_IDS:
            m = raw_meta.get(mid, {})
            if isinstance(m, dict):
                purpose = str(m.get("purpose", "")).strip()
                if purpose:
                    store["_meta"][mid]["purpose"] = purpose
                active = m.get("active_project")
                if isinstance(active, str) and active in store[mid]:
                    store["_meta"][mid]["active_project"] = active

    return store


def _save_raw_store_unlocked(store: dict[str, Any]) -> None:
    with open(PROJECT_FILE, "w", encoding="utf-8") as f:
        json.dump(store, f, indent=4)


def load_all_projects() -> dict[str, dict[str, dict[str, int]]]:
    with _store_lock:
        store = _load_raw_store_unlocked()
        return {mid: store[mid] for mid in MOTOR_IDS}


def load_projects(motor_id: str) -> dict[str, dict[str, int]]:
    with _store_lock:
        store = _load_raw_store_unlocked()
        return dict(store.get(motor_id, {}))


def save_projects(motor_id: str, projects: dict[str, dict[str, int]]) -> None:
    with _store_lock:
        store = _load_raw_store_unlocked()
        store[motor_id] = projects
        active = store["_meta"][motor_id].get("active_project")
        if active and active not in projects:
            store["_meta"][motor_id]["active_project"] = None
        _save_raw_store_unlocked(store)


def get_motor_meta(motor_id: str) -> dict[str, Any]:
    with _store_lock:
        store = _load_raw_store_unlocked()
        return dict(store["_meta"].get(motor_id, {}))


def update_motor_meta(motor_id: str, **updates: Any) -> dict[str, Any]:
    with _store_lock:
        store = _load_raw_store_unlocked()
        meta = store["_meta"].setdefault(
            motor_id,
            {"purpose": MOTORS[motor_id].default_purpose, "active_project": None},
        )
        for key, value in updates.items():
            if key in ("purpose", "active_project"):
                meta[key] = value
        _save_raw_store_unlocked(store)
        return dict(meta)


# ==========================
# HELPERS
# ==========================


def motor_or_404(motor_id: str):
    motor = get_motor(motor_id)
    if motor is None:
        abort(404)
    return motor


def enrich_motor_info(motor_id: str) -> dict[str, Any]:
    info = MOTORS[motor_id].info()
    meta = get_motor_meta(motor_id)
    info["purpose"] = meta.get("purpose") or info.get("default_purpose") or ""
    info["active_project"] = meta.get("active_project")
    return info


def command_response(motor, command: str, reply: str | None):
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
        motors=[enrich_motor_info(mid) for mid in MOTOR_IDS],
        projects=load_all_projects(),
        clear_limit_steps=CLEAR_LIMIT_STEPS,
        stlink_default_motor=STLINK_DEFAULT_MOTOR,
    )


# ==========================
# MOTOR CONNECTION & METADATA
# ==========================


@app.route("/api/motors")
@login_required
def api_motors():
    return jsonify([enrich_motor_info(mid) for mid in MOTOR_IDS])


@app.route("/api/motor/<motor_id>/connect", methods=["POST"])
@login_required
def motor_connect(motor_id: str):
    motor = motor_or_404(motor_id)
    motor.disconnect()
    motor.connect(force=True)
    return jsonify(enrich_motor_info(motor_id))


@app.route("/api/motors/connect_all", methods=["POST"])
@login_required
def motors_connect_all():
    for mid in MOTOR_IDS:
        MOTORS[mid].disconnect()
    connect_all()
    return jsonify(
        {
            "ok": True,
            "motors": [enrich_motor_info(mid) for mid in MOTOR_IDS],
        }
    )


@app.route("/api/motor/<motor_id>/purpose", methods=["POST"])
@login_required
def set_motor_purpose(motor_id: str):
    motor_or_404(motor_id)
    data = request.get_json(silent=True) or {}
    purpose = str(data.get("purpose", "")).strip()
    if not purpose:
        purpose = MOTORS[motor_id].default_purpose
    meta = update_motor_meta(motor_id, purpose=purpose[:80])
    return jsonify({"ok": True, "motor": motor_id, "purpose": meta["purpose"]})


# ==========================
# MOTOR STATUS & TELEMETRY
# ==========================


@app.route("/api/motor/<motor_id>/status")
@login_required
def motor_status(motor_id: str):
    motor = motor_or_404(motor_id)
    meta = get_motor_meta(motor_id)

    status = motor.status()
    if status is None:
        return jsonify(
            {
                "error": "NO RESPONSE",
                "connected": motor.connected,
                "port": motor.port,
                "purpose": meta.get("purpose", motor.default_purpose),
                "active_project": meta.get("active_project"),
                "message": motor.last_error or "Arduino not connected",
            }
        )

    status["connected"] = True
    status["port"] = motor.port
    status["purpose"] = meta.get("purpose", motor.default_purpose)
    status["active_project"] = meta.get("active_project")
    return jsonify(status)


@app.route("/api/motor/<motor_id>/position")
@login_required
def motor_position(motor_id: str):
    motor = motor_or_404(motor_id)
    return jsonify({"position": motor.position(), "connected": motor.connected})


# ==========================
# MOTOR ACTIONS
# ==========================

ACTIONS = {
    "home": "HOME",
    "stop": "STOP",
    "estop": "STOP",
    "hard_estop": "ESTOP",
    "move_forward": "FORWARD",
    "move_backward": "BACKWARD",
    "jog_forward": "JOG 1",
    "jog_backward": "JOG -1",
    "save_forward": "SAVE_FORWARD",
    "save_backward": "SAVE_BACKWARD",
    "clear_limits": "CLEAR_LIMITS",
    "save_position": "SAVE_POSITION",
    "reset_state": "RESET_STATE",
    "driver_off": "DRIVER_OFF",
    "driver_on": "DRIVER_ON",
}


@app.route("/api/motor/<motor_id>/action/<action_name>", methods=["POST"])
@login_required
def motor_action(motor_id: str, action_name: str):
    motor = motor_or_404(motor_id)

    if action_name not in ACTIONS:
        return jsonify({"ok": False, "error": "UNKNOWN ACTION"}), 404

    command = ACTIONS[action_name]
    reply = motor.send(command)

    if reply is not None and action_name in ("clear_limits", "save_forward", "save_backward"):
        update_motor_meta(motor_id, active_project=None)

    return command_response(motor, command, reply)


@app.route("/api/motors/estop_all", methods=["POST"])
@login_required
def motors_estop_all():
    results = {}
    for mid in MOTOR_IDS:
        motor = MOTORS[mid]
        reply = motor.send("ESTOP")
        results[mid] = {
            "ok": reply is not None,
            "response": reply,
            "connected": motor.connected,
            "error": None if reply is not None else (motor.last_error or "NO RESPONSE"),
        }
    return jsonify({"ok": True, "results": results})


@app.route("/api/motor/<motor_id>/command", methods=["POST"])
@login_required
def motor_command(motor_id: str):
    motor = motor_or_404(motor_id)
    data = request.get_json(silent=True) or {}
    command = str(data.get("command", "")).strip()

    if not command:
        return jsonify({"ok": False, "error": "MISSING COMMAND"}), 400

    reply = motor.send(command)
    return command_response(motor, command, reply)


# ==========================
# PER-MOTOR PROJECTS
# ==========================


@app.route("/api/motor/<motor_id>/projects")
@login_required
def motor_projects(motor_id: str):
    motor_or_404(motor_id)
    return jsonify(load_projects(motor_id))


@app.route("/api/motor/<motor_id>/projects", methods=["POST"])
@login_required
def add_project(motor_id: str):
    motor = motor_or_404(motor_id)
    data = request.get_json(silent=True)

    if not data:
        return jsonify({"ok": False, "error": "MISSING REQUEST DATA"}), 400

    name = str(data.get("name", "")).strip()
    if not name:
        return jsonify({"ok": False, "error": "PROJECT NAME IS REQUIRED"}), 400

    try:
        forward_val = int(data.get("forward", ""))
        backward_val = int(data.get("backward", ""))
    except (ValueError, TypeError):
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "FORWARD AND BACKWARD LIMITS MUST BE WHOLE NUMBERS",
                }
            ),
            400,
        )

    if backward_val > forward_val:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "BACKWARD LIMIT CANNOT EXCEED FORWARD LIMIT",
                }
            ),
            400,
        )

    projects = load_projects(motor_id)
    projects[name] = {
        "forward": forward_val,
        "backward": backward_val,
    }
    save_projects(motor_id, projects)

    return jsonify(
        {
            "ok": True,
            "message": "PROJECT SAVED",
            "motor": motor.id,
            "name": name,
            "project": projects[name],
            "projects": projects,
        }
    )


@app.route("/api/motor/<motor_id>/projects/<name>/load", methods=["POST"])
@login_required
def select_project(motor_id: str, name: str):
    motor = motor_or_404(motor_id)
    projects = load_projects(motor_id)

    if name not in projects:
        return jsonify({"ok": False, "error": "PROJECT NOT FOUND"}), 404

    project = projects[name]
    command = f"LOAD_LIMITS,{project['forward']},{project['backward']}"
    reply = motor.send(command)

    if reply is not None:
        update_motor_meta(motor_id, active_project=name)

    result = command_response(motor, command, reply).get_json()
    result["project"] = name
    result["limits"] = project
    return jsonify(result)


@app.route("/api/motor/<motor_id>/projects/<name>", methods=["DELETE"])
@login_required
def delete_project(motor_id: str, name: str):
    motor_or_404(motor_id)
    projects = load_projects(motor_id)

    if name not in projects:
        return jsonify({"ok": False, "error": "PROJECT NOT FOUND"}), 404

    del projects[name]
    save_projects(motor_id, projects)

    return jsonify(
        {
            "ok": True,
            "message": "PROJECT DELETED",
            "name": name,
            "projects": projects,
        }
    )


# ==========================
# ST-LINK / STM32H743 FLASH
# ==========================


def _wait_motor_ready(motor, timeout_sec: float = 35.0, poll_interval: float = 0.35) -> dict[str, Any] | None:
    """Poll motor status until it returns to READY (or ESTOP / timeout)."""
    deadline = time.monotonic() + timeout_sec
    last_status = None
    while time.monotonic() < deadline:
        time.sleep(poll_interval)
        st = motor.status()
        if st is None:
            continue
        last_status = st
        state_name = str(st.get("state", "")).upper()
        if state_name == "READY":
            return st
        if "EMERGENCY" in state_name:
            return st
    return last_status


@app.route("/api/stlink/status")
@app.route("/stlink/status")
@login_required
def stlink_status():
    info = stlink.quick_status()
    info["default_motor"] = STLINK_DEFAULT_MOTOR
    return jsonify(info)


@app.route("/api/stlink/contact", methods=["POST"])
@app.route("/stlink/contact", methods=["POST"])
@login_required
def stlink_contact():
    data = request.get_json(silent=True) or {}
    motor_id = str(data.get("motor") or STLINK_DEFAULT_MOTOR).strip()
    motor = get_motor(motor_id)
    if motor is None:
        return jsonify({"ok": False, "state": "invalid_motor", "error": f"Unknown motor: {motor_id}"}), 400

    if data.get("load_h7", True):
        projects = load_projects(motor_id)
        if "H7" in projects:
            p = projects["H7"]
            motor.send(f"LOAD_LIMITS,{p['forward']},{p['backward']}")
            update_motor_meta(motor_id, active_project="H7")

    reply = motor.send("JOG 1")
    if reply is None:
        return jsonify(
            {
                "ok": False,
                "state": "motor_offline",
                "motor": motor_id,
                "port": motor.port,
                "error": motor.last_error or "Motor controller offline",
            }
        ), 503

    final_status = _wait_motor_ready(motor, timeout_sec=35.0)
    if not final_status or str(final_status.get("state", "")).upper() != "READY":
        return jsonify(
            {
                "ok": False,
                "state": "contact_timeout",
                "motor": motor_id,
                "status": final_status,
            }
        )

    return jsonify(
        {
            "ok": True,
            "state": "contact_ready",
            "motor": motor_id,
            "position": final_status.get("position"),
            "forward": final_status.get("forward"),
        }
    )


@app.route("/api/stlink/probe", methods=["POST"])
@app.route("/stlink/probe", methods=["POST"])
@login_required
def stlink_probe():
    return jsonify(stlink.probe())


@app.route("/api/stlink/flash", methods=["POST"])
@app.route("/stlink/flash", methods=["POST"])
@login_required
def stlink_flash_image():
    data = request.get_json(silent=True) or {}
    image_name = data.get("image")
    base = str(data.get("base") or "").strip() or None

    resolved = stlink.resolve_image(image_name)
    if resolved is None:
        return (
            jsonify(
                {
                    "ok": False,
                    "state": "missing_image",
                    "log": f"Flash image not found: {image_name or '(default)'}",
                }
            ),
            404,
        )

    return jsonify(stlink.flash(resolved, base=base))


@app.route("/api/stlink/run", methods=["POST"])
@app.route("/stlink/run", methods=["POST"])
@login_required
def stlink_soft_run():
    return jsonify(stlink.soft_run())


@app.route("/api/stlink/power_cycle", methods=["POST"])
@app.route("/stlink/power_cycle", methods=["POST"])
@login_required
def stlink_power_cycle():
    data = request.get_json(silent=True) or {}
    motor_id = str(data.get("motor") or STLINK_DEFAULT_MOTOR).strip()
    motor = get_motor(motor_id)
    if motor is None:
        return jsonify({"ok": False, "state": "invalid_motor", "error": f"Unknown motor: {motor_id}"}), 400

    retract_reply = motor.send("JOG -1")
    if retract_reply is None:
        return (
            jsonify(
                {
                    "ok": False,
                    "state": "motor_offline",
                    "motor": motor_id,
                    "error": motor.last_error or "Motor controller offline",
                }
            ),
            503,
        )

    retracted = _wait_motor_ready(motor, timeout_sec=35.0)
    if not retracted or str(retracted.get("state", "")).upper() != "READY":
        return jsonify({"ok": False, "state": "retract_timeout", "status": retracted})

    time.sleep(1.0)

    contact_reply = motor.send("JOG 1")
    if contact_reply is None:
        return jsonify({"ok": False, "state": "reseat_failed", "motor": motor_id}), 503

    seated = _wait_motor_ready(motor, timeout_sec=35.0)
    ok = bool(seated and str(seated.get("state", "")).upper() == "READY")
    return jsonify(
        {
            "ok": ok,
            "state": "ok" if ok else "reseat_timeout",
            "motor": motor_id,
            "position": seated.get("position") if seated else None,
        }
    )


# ==========================
# ENTRYPOINT
# ==========================

if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "5000")),
        debug=os.environ.get("FLASK_DEBUG", "0") == "1",
    )
