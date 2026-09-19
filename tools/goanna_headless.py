#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Run a Goanna client, or the vanilla Luanti client, where nobody sees it.

Test clients used to open ordinary windows on the owner's desktop, take the
focus, grab the mouse, and in one case have their pointer moved with
xdotool, while the owner was working and once in the middle of a video call.
Everything started here runs inside gamescope's headless backend instead: a
compositor with its own nested X display and no output at all, so the
client renders on the GPU (or on the CPU with software=True) and no window,
pointer grab or focus change can reach the desktop. Input comes only from
inside the client, through the control channel's ui_* and key commands
(docs/control-channel.md).

Each instance has a supervisor process of its own, detached from whatever
started it. It starts gamescope, watches the client, and when the client
exits, or when it is asked to stop, stops the client and then gamescope,
which otherwise outlives its child and ignores SIGTERM. It kills only
processes it started: the client and its descendants, and gamescope's own
process group inside the supervisor's session, each checked against the
start time recorded when it was launched so a reused PID is never touched.
Nothing is ever killed by name.

State lives in $XDG_RUNTIME_DIR/goanna-headless/<id>.json, so the MCP server
(tools/goanna-mcp), this module's command line (tools/goanna-headless) and a
second agent can all see which instances are running and on which ports.

Two instances at once is expected to work but is something to verify, not
something to assume: on 2026-09-19 the NVIDIA driver on the author's machine
went into a reset-required state (Xid 51 and 154) within a minute of two
headless gamescope sessions starting, and whether they caused it is not
known. software=True renders on lavapipe and llvmpipe and never creates a
GPU context, at a much lower frame rate.
"""

import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

LAVAPIPE_DEVICE = "10005:0000"        # Mesa's vendor id, llvmpipe's device id
LAVAPIPE_ICD = "/usr/share/vulkan/icd.d/lvp_icd.x86_64.json"
MESA_EGL = "/usr/share/glvnd/egl_vendor.d/50_mesa.json"
NO_DESKTOP = "goanna-headless-no-desktop"   # a Wayland socket that does not exist
FLATPAK_APP = "org.luanti.luanti"
DEFAULT_CONTROL_PORT = 30800

# The child's first act inside gamescope: say which display it was given and
# what its PID is, then become the client. WAYLAND_DISPLAY is pointed at a
# socket that does not exist, because a Wayland client with the variable
# unset falls back to wayland-0, which on this kind of machine is the
# desktop itself.
WRAPPER = ('export WAYLAND_DISPLAY=' + NO_DESKTOP + '; '
           'printf "DISPLAY=%s\\nGAMESCOPE_WAYLAND_DISPLAY=%s\\n" '
           '"$DISPLAY" "$GAMESCOPE_WAYLAND_DISPLAY" > "$0"; '
           'echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; shift; exec "$@"')


class LaunchError(RuntimeError):
    pass


def log(*parts):
    print(*parts, file=sys.stderr, flush=True)


# --- where things live -------------------------------------------------------

def state_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    path = pathlib.Path(base) / "goanna-headless"
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def log_root():
    base = os.environ.get("GOANNA_HEADLESS_LOG_DIR") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "goanna-headless")
    path = pathlib.Path(base)
    path.mkdir(parents=True, exist_ok=True)
    return path


def flatpak_home(app=FLATPAK_APP):
    """A directory the Flatpak sandbox sees at the same path: its own."""
    path = pathlib.Path.home() / ".var" / "app" / app / "goanna-headless"
    path.mkdir(parents=True, exist_ok=True)
    return path


def record_path(ident):
    if not ident or "/" in ident or ident.startswith("."):
        raise LaunchError("'%s' is not an instance id" % ident)
    return state_dir() / (ident + ".json")


def load(ident):
    path = record_path(ident)
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        raise LaunchError("no instance '%s'; list shows the ones that exist" % ident)


def save(rec):
    path = record_path(rec["id"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(rec, indent=2, sort_keys=True))
    tmp.replace(path)


# --- processes, by PID and start time only -----------------------------------

def proc_stat(pid):
    """(state, ppid, pgrp, session, starttime) from /proc, or None."""
    try:
        raw = pathlib.Path("/proc/%d/stat" % int(pid)).read_text()
    except (OSError, ValueError, TypeError):
        return None
    rest = raw[raw.rfind(")") + 2:].split()
    return rest[0], int(rest[1]), int(rest[2]), int(rest[3]), int(rest[19])


def proc_start(pid):
    st = proc_stat(pid)
    return st[4] if st and st[0] != "Z" else None


def alive(pid, start):
    """The process we started, still running: same PID and same start time."""
    return bool(pid) and start is not None and proc_start(pid) == start


def descendants(pid):
    """Every process below pid, deepest first."""
    children = {}
    for entry in pathlib.Path("/proc").iterdir():
        if entry.name.isdigit():
            st = proc_stat(entry.name)
            if st:
                children.setdefault(st[1], []).append(int(entry.name))
    out, stack = [], [int(pid)]
    while stack:
        for child in children.get(stack.pop(), []):
            out.append(child)
            stack.append(child)
    out.reverse()
    return out


def group_members(pgid, session):
    """Processes in process group pgid inside our own session."""
    out = []
    for entry in pathlib.Path("/proc").iterdir():
        if entry.name.isdigit():
            st = proc_stat(entry.name)
            if st and st[2] == pgid and st[3] == session and st[0] != "Z":
                out.append(int(entry.name))
    return out


def signal_pid(pid, sig):
    try:
        os.kill(pid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def wait_gone(pids_starts, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(alive(p, s) for p, s in pids_starts):
            return True
        time.sleep(0.1)
    return not any(alive(p, s) for p, s in pids_starts)


# --- ports -------------------------------------------------------------------

def port_free(port):
    """Whether nothing holds 127.0.0.1:port. SO_REUSEADDR so that a closed
    connection in TIME_WAIT does not count, which a listener still does."""
    port = int(port)
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(("127.0.0.1", port))
    except OSError:
        return False
    finally:
        probe.close()
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
        return False
    except OSError:
        return True


def ports_in_use_by_records():
    out = set()
    for rec in list_records():
        if rec.get("status") in ("starting", "running") and rec.get("control_port"):
            out.add(int(rec["control_port"]))
    return out


def free_control_port(start=DEFAULT_CONTROL_PORT, span=100):
    taken = ports_in_use_by_records()
    for port in range(start, start + span):
        if port not in taken and port_free(port):
            return port
    raise LaunchError("no free control port from %d to %d" % (start, start + span - 1))


# --- finding things ----------------------------------------------------------

def resolve_project(path):
    """A Goanna checkout or worktree, or its project directory."""
    p = pathlib.Path(path).expanduser().resolve()
    if (p / "project" / "project.godot").exists():
        return p / "project"
    if (p / "project.godot").exists():
        return p
    raise LaunchError("%s is neither a Goanna checkout nor its project directory" % p)


def find_godot(project=None):
    for cand in (os.environ.get("GODOT_BIN"), "godot", "godot4"):
        if cand:
            found = shutil.which(cand) or (cand if os.access(cand, os.X_OK) else None)
            if found:
                return found
    # The binary usually sits beside the checkout. A worktree is further down,
    # under .claude/worktrees, so look in every ancestor.
    starts = [pathlib.Path(project)] if project else []
    starts.append(pathlib.Path(__file__).resolve())
    for start in starts:
        for parent in start.parents:
            for hit in sorted(parent.glob("Godot_v4*_linux.x86_64"), reverse=True):
                if os.access(hit, os.X_OK):
                    return str(hit)
    raise LaunchError("no Godot binary found; set GODOT_BIN")


def need(tool):
    if not shutil.which(tool):
        raise LaunchError("%s is not installed; the headless launcher needs it" % tool)


# --- launching ---------------------------------------------------------------

def list_records():
    out = []
    for path in sorted(state_dir().glob("*.json")):
        try:
            rec = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        # A supervisor killed outright never wrote "stopped"; say what is true.
        if rec.get("status") in ("starting", "running") \
                and not alive(rec.get("supervisor_pid"), rec.get("supervisor_start")) \
                and not alive(rec.get("child_pid"), rec.get("child_start")):
            rec["status"] = "stopped"
            rec.setdefault("reason", "gone (its supervisor did not record why)")
            try:
                save(rec)
            except OSError:
                pass
        out.append(rec)
    return out


def _spawn(rec, timeout=60.0):
    """Start the supervisor for a prepared record and wait until the client
    process exists inside gamescope, or until it fails."""
    need("gamescope")
    existing = None
    try:
        existing = load(rec["id"])
    except LaunchError:
        pass
    if existing and existing.get("status") in ("starting", "running") and (
            alive(existing.get("supervisor_pid"), existing.get("supervisor_start"))
            or alive(existing.get("child_pid"), existing.get("child_start"))):
        raise LaunchError("instance %s is already running (supervisor %s, client %s)"
                          % (rec["id"], existing.get("supervisor_pid"), existing.get("child_pid")))
    rec.update(status="launching", created=time.time(), started_by=os.getppid())
    logs = pathlib.Path(rec["log_dir"])
    logs.mkdir(parents=True, exist_ok=True)
    save(rec)
    sup_log = open(logs / "supervisor.log", "ab")
    proc = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()),
                             "_supervise", rec["id"]],
                            stdin=subprocess.DEVNULL, stdout=sup_log, stderr=subprocess.STDOUT,
                            start_new_session=True, close_fds=True)
    sup_log.close()
    deadline = time.time() + timeout
    while time.time() < deadline:
        cur = load(rec["id"])
        if cur.get("status") == "running":
            return cur
        if cur.get("status") in ("failed", "stopped"):
            raise LaunchError("instance %s did not start: %s. Logs: %s"
                              % (rec["id"], cur.get("reason", "unknown"), rec["log_dir"]))
        if proc.poll() is not None and cur.get("status") != "running":
            raise LaunchError("the supervisor for %s exited (%d) before the client started. "
                              "Logs: %s" % (rec["id"], proc.returncode, rec["log_dir"]))
        time.sleep(0.1)
    stop(rec["id"])
    raise LaunchError("instance %s did not start within %gs. Logs: %s"
                      % (rec["id"], timeout, rec["log_dir"]))


def _base_record(ident, kind, width, height, software):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return {"id": ident, "kind": kind, "width": int(width), "height": int(height),
            "software": bool(software),
            "log_dir": str(log_root() / ("%s-%s" % (ident, stamp)))}


def start_goanna(project, control_port=None, host="127.0.0.1", port=30000, name="dev",
                 password="", width=1280, height=720, software=False, env=None, label="",
                 ready_timeout=120.0):
    """Start Goanna from project (a checkout, a worktree or its project
    directory) in headless gamescope, with its control channel on
    control_port, and return once that channel answers."""
    project = resolve_project(project)
    godot = find_godot(project)
    if control_port is None:
        control_port = free_control_port()
    control_port = int(control_port)
    # Two agents once drove each other's clients because they shared a port.
    # Refuse rather than pick another: the caller named this one, and will
    # send its commands there.
    if not port_free(control_port):
        raise LaunchError("control port %d is already in use; pick another, or leave it "
                          "out and one is chosen" % control_port)
    rec = _base_record("goanna-%d" % control_port, "goanna", width, height, software)
    child_env = {
        "GOANNA_CONTROL": str(control_port),
        "GOANNA_NO_POINTER_CAPTURE": "1",
        "GOANNA_HOST": str(host),
        "GOANNA_PORT": str(int(port)),
        "GOANNA_NAME": str(name),
        "GOANNA_PASS": str(password or ""),
        "GOANNA_TEST_LABEL": str(label or "headless %s" % name),
    }
    if software:
        child_env.update({"VK_DRIVER_FILES": LAVAPIPE_ICD, "VK_ICD_FILENAMES": LAVAPIPE_ICD})
    child_env.update({str(k): str(v) for k, v in (env or {}).items()})
    rec.update(project=str(project), control_port=control_port, server="%s:%d" % (host, int(port)),
               name=str(name), env=child_env,
               argv=[godot, "--display-driver", "x11", "--resolution",
                     "%dx%d" % (int(width), int(height)), "--path", str(project)],
               client_log=str(pathlib.Path(rec["log_dir"]) / "output.log"))
    rec = _spawn(rec)
    deadline = time.time() + ready_timeout
    while time.time() < deadline:
        cur = load(rec["id"])
        if cur.get("status") != "running":
            raise LaunchError("the client exited during startup: %s. Its log is %s\n%s"
                              % (cur.get("reason"), rec["client_log"], tail(rec["client_log"])))
        if control_ping(control_port):
            return cur
        time.sleep(0.5)
    stop(rec["id"])
    raise LaunchError("the control channel on %d never opened. The log is %s\n%s"
                      % (control_port, rec["client_log"], tail(rec["client_log"])))


def start_vanilla(host="127.0.0.1", port=30000, name="vanilla", password="", width=1280,
                  height=720, software=False, settings=None, app=FLATPAK_APP):
    """Start the vanilla Luanti client (the Flatpak) in headless gamescope,
    joined straight to host:port, with a configuration file of its own so
    the owner's own client settings are never touched."""
    need("flatpak")
    ident = "vanilla-%s-%d" % ("".join(c for c in str(name) if c.isalnum() or c in "_-"),
                               int(port))
    rec = _base_record(ident, "vanilla", width, height, software)
    home = flatpak_home(app) / ident
    home.mkdir(parents=True, exist_ok=True)
    conf = {"screen_w": int(width), "screen_h": int(height), "autosave_screensize": "false",
            "fullscreen": "false", "enable_sound": "false", "mute_sound": "true",
            "name": str(name)}
    conf.update(settings or {})
    (home / "client.conf").write_text("".join("%s = %s\n" % kv for kv in conf.items()))
    argv = ["flatpak", "run", "--die-with-parent", "--nosocket=wayland", "--socket=x11",
            "--unset-env=WAYLAND_DISPLAY", "--env=SDL_VIDEODRIVER=x11"]
    if software:
        argv += ["--env=LIBGL_ALWAYS_SOFTWARE=1", "--env=__GLX_VENDOR_LIBRARY_NAME=mesa",
                 "--env=MESA_LOADER_DRIVER_OVERRIDE=llvmpipe"]
    argv += ["--command=luanti", app, "--config", str(home / "client.conf"),
             "--logfile", str(home / "client.log"),
             "--address", str(host), "--port", str(int(port)), "--name", str(name)]
    if password:
        pw = home / "password"
        pw.write_text(str(password))
        pw.chmod(0o600)
        argv += ["--password-file", str(pw)]
    argv.append("--go")
    rec.update(server="%s:%d" % (host, int(port)), name=str(name), env={}, argv=argv,
               client_log=str(home / "client.log"), config=str(home / "client.conf"))
    return _spawn(rec)


def tail(path, lines=20):
    try:
        return "\n".join(pathlib.Path(path).read_text(errors="replace").strip()
                         .split("\n")[-lines:])
    except OSError:
        return ""


def control_ping(port):
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=2.0) as sock:
            sock.settimeout(5.0)
            sock.sendall(b'{"id": 1, "cmd": "ping"}\n')
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    return False
                buf += chunk
        return bool(json.loads(buf.split(b"\n", 1)[0]).get("ok"))
    except (OSError, ValueError):
        return False


# --- the supervisor ----------------------------------------------------------

def _gamescopectl(rec, args, timeout=10):
    """A command to this instance's own gamescope, over its own socket."""
    if not rec.get("gamescope_socket"):
        return False
    env = dict(os.environ, GAMESCOPE_WAYLAND_DISPLAY=rec["gamescope_socket"])
    try:
        subprocess.run(["gamescopectl"] + list(args), env=env, timeout=timeout,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


def _stop_client(rec):
    """Stop the client and everything below it, politely first."""
    pid, start = rec.get("child_pid"), rec.get("child_start")
    if not alive(pid, start):
        return
    if rec.get("kind") == "goanna" and rec.get("control_port"):
        # The client is ours and alive, so the port is still its own. A quit
        # over the channel disconnects cleanly, so the server sees the player
        # leave instead of timing out.
        try:
            with socket.create_connection(("127.0.0.1", int(rec["control_port"])),
                                          timeout=2.0) as sock:
                sock.sendall(b'{"id": 1, "cmd": "quit"}\n')
                sock.settimeout(5.0)
                sock.recv(4096)
        except OSError:
            pass
        if wait_gone([(pid, start)], 8.0):
            return
    below = [(p, proc_start(p)) for p in descendants(pid)]
    for p, s in below + [(pid, start)]:
        if alive(p, s):
            signal_pid(p, signal.SIGTERM)
    if wait_gone(below + [(pid, start)], 10.0):
        return
    for p, s in below + [(pid, start)]:
        if alive(p, s):
            signal_pid(p, signal.SIGKILL)
    wait_gone(below + [(pid, start)], 5.0)


def _stop_gamescope(rec, proc=None):
    """gamescope outlives its child and ignores SIGTERM. Ask it to shut down
    over its own control socket, then kill its process group, and then
    anything left in that group inside our session, Xwayland included."""
    pid, start = rec.get("gamescope_pid"), rec.get("gamescope_start")
    if alive(pid, start):
        _gamescopectl(rec, ["shutdown"], timeout=5)
        wait_gone([(pid, start)], 5.0)
    if alive(pid, start):
        try:
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            signal_pid(pid, signal.SIGKILL)
    if proc is not None:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    session = rec.get("session")
    if pid and session:
        for member in group_members(int(pid), int(session)):
            signal_pid(member, signal.SIGKILL)


def supervise(ident):
    rec = load(ident)
    flags = {"stop": False}

    def on_signal(signum, frame):
        flags["stop"] = True

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)
    me = os.getpid()
    logs = pathlib.Path(rec["log_dir"])
    envfile = state_dir() / (ident + ".env")
    pidfile = state_dir() / (ident + ".pid")
    for stale in (envfile, pidfile):
        stale.unlink(missing_ok=True)
    w, h = str(rec["width"]), str(rec["height"])
    argv = ["gamescope"]
    if rec.get("software"):
        argv += ["--prefer-vk-device", LAVAPIPE_DEVICE]
    argv += ["--backend", "headless", "-W", w, "-H", h, "-w", w, "-h", h, "--",
             "sh", "-c", WRAPPER, str(envfile), str(pidfile)]
    if rec.get("software"):
        # gamescope sets ENABLE_GAMESCOPE_WSI=1 for its child, and its WSI layer
        # cannot present from lavapipe: the client loops on swapchain errors.
        # env execs the client, so the PID the wrapper wrote stays the client's.
        argv += ["env", "ENABLE_GAMESCOPE_WSI=0"]
    argv += list(rec["argv"])
    # Nothing in here may reach the desktop: no DISPLAY, and no
    # WAYLAND_DISPLAY (gamescope connects to one if it is set). The child
    # gets gamescope's own nested display.
    env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY")}
    if rec.get("software"):
        env.update({"LIBGL_ALWAYS_SOFTWARE": "1", "__EGL_VENDOR_LIBRARY_FILENAMES": MESA_EGL})
    env.update(rec.get("env") or {})
    # gamescope's output and the client's stdout, together. For Goanna that is
    # the client's log; the vanilla client keeps its own, in client_log.
    output = open(logs / "output.log", "ab")
    gs = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=output,
                          stderr=subprocess.STDOUT, process_group=0, close_fds=True)
    output.close()
    rec.update(status="starting", supervisor_pid=me, supervisor_start=proc_start(me),
               session=os.getsid(0), gamescope_pid=gs.pid, gamescope_start=proc_start(gs.pid))
    save(rec)
    reason = None
    deadline = time.time() + 60.0
    while not pidfile.exists():
        if flags["stop"]:
            reason = "stop requested during startup"
        elif gs.poll() is not None:
            reason = "gamescope exited during startup (%d); see %s" % (
                gs.returncode, logs / "output.log")
        elif time.time() > deadline:
            reason = "the client never started inside gamescope"
        if reason:
            _stop_gamescope(rec, gs)
            rec.update(status="failed", reason=reason, stopped_at=time.time())
            save(rec)
            return 1
        time.sleep(0.1)
    child = int(pidfile.read_text().strip())
    info = {}
    for line in envfile.read_text().splitlines():
        key, _, value = line.partition("=")
        info[key] = value
    rec.update(status="running", child_pid=child, child_start=proc_start(child),
               display=info.get("DISPLAY", ""),
               gamescope_socket=info.get("GAMESCOPE_WAYLAND_DISPLAY", ""))
    save(rec)
    while True:
        if flags["stop"]:
            reason = "stop requested"
            break
        if gs.poll() is not None:
            reason = "gamescope exited (%d)" % gs.returncode
            break
        if not alive(rec["child_pid"], rec["child_start"]):
            reason = "the client exited"
            break
        time.sleep(0.25)
    _stop_client(rec)
    _stop_gamescope(rec, gs)
    rec.update(status="stopped", reason=reason, stopped_at=time.time())
    save(rec)
    for path in (envfile, pidfile):
        path.unlink(missing_ok=True)
    return 0


# --- using an instance -------------------------------------------------------

def stop(ident, timeout=40.0):
    """Stop one instance: its supervisor if it is alive, which stops the
    client and gamescope in order, or those two directly if it is not."""
    rec = load(ident)
    sup = (rec.get("supervisor_pid"), rec.get("supervisor_start"))
    stopped = []
    if alive(*sup):
        signal_pid(sup[0], signal.SIGTERM)
        wait_gone([sup], timeout)
        if alive(*sup):
            signal_pid(sup[0], signal.SIGKILL)
        else:
            stopped.append("supervisor %d" % sup[0])
        rec = load(ident)
    if alive(rec.get("child_pid"), rec.get("child_start")):
        _stop_client(rec)
        stopped.append("client %d" % rec["child_pid"])
    if alive(rec.get("gamescope_pid"), rec.get("gamescope_start")):
        _stop_gamescope(rec)
        stopped.append("gamescope %d" % rec["gamescope_pid"])
    if rec.get("status") in ("launching", "starting", "running"):
        rec.update(status="stopped", reason="stopped from outside", stopped_at=time.time())
        save(rec)
    left = [name for name, pid, start in (
        ("client", rec.get("child_pid"), rec.get("child_start")),
        ("gamescope", rec.get("gamescope_pid"), rec.get("gamescope_start")))
        if alive(pid, start)]
    return {"id": ident, "stopped": stopped, "still_running": left, "status": rec.get("status")}


def screenshot(ident, path, timeout=20.0):
    """The whole virtual display as gamescope composites it, written by
    gamescope itself. Works for any client, the vanilla one included."""
    rec = load(ident)
    if not alive(rec.get("gamescope_pid"), rec.get("gamescope_start")):
        raise LaunchError("instance %s has no running gamescope" % ident)
    need("gamescopectl")
    path = pathlib.Path(path).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    _gamescopectl(rec, ["screenshot", str(path)])
    deadline = time.time() + timeout
    last = -1
    while time.time() < deadline:
        if path.exists():
            size = path.stat().st_size
            if size > 0 and size == last:
                return {"id": ident, "path": str(path), "bytes": size,
                        "size": [rec["width"], rec["height"]]}
            last = size
        time.sleep(0.3)
    raise LaunchError("gamescope wrote no screenshot to %s within %gs" % (path, timeout))


def describe(rec):
    """The parts of a record worth showing."""
    keys = ("id", "kind", "status", "reason", "control_port", "server", "name", "project",
            "width", "height", "software", "display", "gamescope_socket", "supervisor_pid",
            "gamescope_pid", "child_pid", "log_dir", "client_log", "started_by")
    return {k: rec[k] for k in keys if k in rec}


# --- command line ------------------------------------------------------------

USAGE = """usage:
  goanna-headless start [--project PATH] [--control-port N] [--server HOST:PORT]
                        [--name NAME] [--password PW] [--size WxH] [--software]
                        [--label TEXT] [--env KEY=VALUE ...]
  goanna-headless vanilla [--server HOST:PORT] [--name NAME] [--password PW]
                        [--size WxH] [--software] [--set KEY=VALUE ...]
  goanna-headless shot ID PATH
  goanna-headless stop ID
  goanna-headless list [--all]
  goanna-headless port-free N
"""


def _parse(argv):
    opts, pos, i = {"env": {}, "set": {}}, [], 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--software", "--all"):
            opts[arg[2:]] = True
        elif arg in ("--env", "--set"):
            key, _, value = argv[i + 1].partition("=")
            opts[arg[2:]][key] = value
            i += 1
        elif arg.startswith("--"):
            if i + 1 >= len(argv):
                raise LaunchError("%s wants a value" % arg)
            opts[arg[2:].replace("-", "_")] = argv[i + 1]
            i += 1
        else:
            pos.append(arg)
        i += 1
    return opts, pos


def _server(opts):
    host, _, port = opts.get("server", "127.0.0.1:30000").rpartition(":")
    return host or "127.0.0.1", int(port)


def _size(opts):
    w, _, h = opts.get("size", "1280x720").partition("x")
    return int(w), int(h)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    cmd, (opts, pos) = argv[1], _parse(argv[2:])
    try:
        if cmd == "_supervise":
            return supervise(pos[0])
        if cmd == "start":
            host, port = _server(opts)
            w, h = _size(opts)
            rec = start_goanna(opts.get("project", pathlib.Path(__file__).resolve().parent.parent),
                               control_port=opts.get("control_port"), host=host, port=port,
                               name=opts.get("name", "dev"), password=opts.get("password", ""),
                               width=w, height=h, software=opts.get("software", False),
                               env=opts["env"], label=opts.get("label", ""))
            out = describe(rec)
        elif cmd == "vanilla":
            host, port = _server(opts)
            w, h = _size(opts)
            out = describe(start_vanilla(host=host, port=port, name=opts.get("name", "vanilla"),
                                         password=opts.get("password", ""), width=w, height=h,
                                         software=opts.get("software", False),
                                         settings=opts["set"]))
        elif cmd == "shot":
            out = screenshot(pos[0], pos[1])
        elif cmd == "stop":
            out = stop(pos[0])
        elif cmd == "list":
            out = [describe(r) for r in list_records()
                   if opts.get("all") or r.get("status") in ("launching", "starting", "running")]
        elif cmd == "port-free":
            out = {"port": int(pos[0]), "free": port_free(int(pos[0]))}
        else:
            print(USAGE, file=sys.stderr)
            return 2
    except (LaunchError, IndexError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
