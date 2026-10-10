#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""One long lived render service that owns the GPU and takes shot jobs.

Agents used to each build a worktree, import it, make a fixture world, start
a server and a headless client, take a few frames and stop, holding the one
GPU lock for 30 to 60 minutes when the frames themselves took a few. This
service does the setup once and keeps it:

- it takes the GPU lock (/tmp/claude-1000/goanna-gpu.lock, the one every
  agent's flock uses) and holds it for its whole life, so nothing else
  renders beside it;
- under the lock it requires `tools/goanna-headless gpu-free` free with no
  driver errors and no foreign compute job on the card;
- it starts one Luanti server on a fixture world it rebuilds (or a copy of
  a named world), with tools/render-fixture.lua and goanna_server_mod as
  worldmods, and one headless Goanna client on the GPU (gamescope on
  lavapipe, Godot on the card) with a profile it writes and then reads
  back;
- it takes jobs from a queue directory, one at a time, applies each job's
  state, shoots, writes into the job's output directory and puts back what
  it changed;
- between jobs it polls nvidia-smi and the process list. When the owner's
  own Godot, a python compute job or a driver fault appears, it stops its
  client and server, releases the lock and waits until the card is clear;
- it stops cleanly on SIGTERM and after an idle timeout, because clients
  left running cost the owner.

docs/agents/agent-interfaces.md, "The render service", is the user's guide and
has a worked job. Everything here runs through tools/goanna_headless.py
for the client, so the launcher's own checks and its PID bookkeeping apply.
"""

import base64
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import goanna_headless as gh  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
LUANTI_HOME = pathlib.Path.home() / ".var/app/org.luanti.luanti"
GAMES = LUANTI_HOME / ".minetest/games"
WORLDS = LUANTI_HOME / ".minetest/worlds"
FLATPAK = ["flatpak", "run", "--command=luanti", "org.luanti.luanti"]
GPU_LOCK = os.environ.get("GOANNA_GPU_LOCK", "/tmp/claude-1000/goanna-gpu.lock")
PLAYER = "render"
DEFAULT_STAGE = (1000, 32, 1000)
# Where the player waits between jobs: far enough from the stage that its
# blocks are dropped, so a job's edits arrive in blocks sent fresh rather
# than as changes to blocks the client already holds (see the occlusion
# fixture of 2026-10-05, whose edits never reached a client parked nearby).
HOME_OFFSET = (0, 40, -1200)
FLOORS = {"mineclonia": "mcl_core:stone", "mineclone2": "mcl_core:stone",
          "minetest_game": "default:stone"}
WEATHER_GAMES = ("mineclonia", "mineclone2")
TIERS = ("lowest", "low", "medium", "high", "ultra")
# Desktop programs nvidia-smi lists beside a game. Anything else in its
# compute list that is not ours counts as a foreign GPU user.
DESKTOP_GPU_USERS = ("kwin_wayland", "xwayland", "plasmashell", "firefox", "freetube",
                     "chrome", "chromium", "electron", "steamwebhelper", "krunner",
                     "kded", "gnome-shell", "mutter", "discord", "code", "spectacle",
                     "brave")
LAUNCH_FIELDS = ("build", "pack", "tier", "size", "env", "maps", "launch_profile")
# Profile keys the client reads only when it joins (texture_size reduces the
# pack's images as the session is built, 2f3f6c35): a job's override of one
# goes into the written profile and restarts the client, rather than being
# set live and silently doing nothing.
LAUNCH_PROFILE_KEYS = ("texture_size",)
# The caller's own GODOT_BIN. Each launch points GODOT_BIN at a wrapper
# that adds --audio-driver Dummy; finding Godot again from that would wrap
# the wrapper, and a second launch into the same directory execs itself.
CALLER_GODOT_BIN = os.environ.get("GODOT_BIN")


class RenderError(RuntimeError):
    pass


class Yield(RuntimeError):
    """The card is wanted by someone else; stop and give it back."""


# --- where things live -------------------------------------------------------

def state_dir():
    """The queue and the service record. GOANNA_RENDER_STATE names another,
    for a second service on another world or game: both still take the one
    GPU lock, so only one of them renders at a time."""
    if os.environ.get("GOANNA_RENDER_STATE"):
        path = pathlib.Path(os.environ["GOANNA_RENDER_STATE"])
    else:
        path = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "goanna-render"
    for sub in ("queue", "running", "done"):
        (path / sub).mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def service_home(world=None):
    """Inside the Flatpak's own directory, which the sandboxed server sees at
    the same absolute path. One directory per world: two services shared
    one server.conf and one debug log, and the second deleted the first's
    log, which its player checks read."""
    path = LUANTI_HOME / "goanna-render"
    if world:
        path = path / pathlib.Path(world).name
    path.mkdir(parents=True, exist_ok=True)
    return path


def main_checkout():
    """The checkout that holds main: the parent of the common git dir, so a
    worktree finds the main tree rather than itself."""
    try:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=REPO,
                                capture_output=True, text=True, timeout=20).stdout.strip()
        if common:
            path = (REPO / common).resolve().parent
            if (path / "project" / "project.godot").exists():
                return path
    except (OSError, subprocess.SubprocessError):
        pass
    return REPO


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def code_stamp():
    """The service's own sources, by size and time."""
    out = []
    for name in ("goanna_render.py", "goanna_headless.py", "render-fixture.lua"):
        try:
            st = (HERE / name).stat()
            out.append((name, st.st_size, st.st_mtime_ns))
        except OSError:
            out.append((name, None, None))
    return out


def log(*parts):
    print(now(), *parts, flush=True)


def write_json(path, data):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True, default=str))
    tmp.replace(path)


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError):
        return None


# --- the control channel -----------------------------------------------------

class Control:
    def __init__(self, port, timeout=600.0):
        self.port = int(port)
        self.timeout = timeout
        self.sock = None
        self.next_id = 0

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def send(self, cmd, args=None, timeout=None):
        if self.sock is None:
            self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=10.0)
        self.sock.settimeout(timeout or self.timeout)
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": self.next_id, "cmd": cmd, "args": args or {}})
                           + "\n").encode())
        data = b""
        try:
            while b"\n" not in data:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise RenderError("the control channel closed during %s" % cmd)
                data += chunk
        except (OSError, socket.timeout) as exc:
            self.close()
            raise RenderError("%s: %s" % (cmd, exc))
        reply = json.loads(data.split(b"\n", 1)[0].decode("utf-8"), strict=False)
        if not reply.get("ok"):
            raise RenderError("%s failed: %s" % (cmd, reply.get("error")))
        return reply.get("result")

    def eval(self, expr):
        got = self.send("eval", {"expr": expr})
        return got.get("value") if isinstance(got, dict) else got

    def run(self, src, timeout=None):
        got = self.send("run", {"src": src}, timeout=timeout)
        return got.get("value") if isinstance(got, dict) and "value" in got else got

    def chat(self, text, expect=None, timeout=20.0):
        """Send a chat line and return (what the server said, refused). With
        expect, keep reading the chat until a line containing it arrives: a
        slow client (software rendering draws a few frames a second) gets
        the reply after the channel's own reply window has closed."""
        t0 = float(self.eval("ui.t") or 0.0) if expect else 0.0
        got = self.send("chat", {"text": text, "reply_ms": 800})
        if not isinstance(got, dict):
            return [], False
        said = list(got.get("server_said") or [])
        refused = bool(got.get("refused"))
        deadline = time.time() + timeout
        while expect and not refused and not any(expect in x for x in said) \
                and time.time() < deadline:
            time.sleep(0.5)
            lines = self.run("var out := []\nfor line in main.ui.chat_lines:\n"
                             "\tif float(line.get(\"time\", 0.0)) > %f:\n"
                             "\t\tout.append(String(line.get(\"text\", \"\")))\nreturn out"
                             % t0) or []
            said = [x for x in lines if expect in x][-1:] or said
        return said, refused


def gd_string(text):
    """A GDScript string literal."""
    return json.dumps(str(text))


# --- the GPU -----------------------------------------------------------------

class GpuLock:
    """The flock every agent takes before a GPU render. Held for the
    service's life, released only while it yields or when it stops."""

    def __init__(self, path=GPU_LOCK):
        self.path = path
        self.fd = None

    def held(self):
        return self.fd is not None

    def acquire(self, stop_flag, on_wait=None):
        pathlib.Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        said = False
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.fd = fd
                return True
            except BlockingIOError:
                if not said and on_wait:
                    on_wait()
                    said = True
                if stop_flag():
                    os.close(fd)
                    return False
                time.sleep(2.0)

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
            self.fd = None


def proc_args(pid):
    try:
        raw = pathlib.Path("/proc/%d/cmdline" % pid).read_bytes()
    except OSError:
        return []
    return [a.decode(errors="replace") for a in raw.split(b"\0") if a]


def foreign_gpu_users(own, fake_file=None, software=False):
    """What on the card is not ours, as strings saying who. Empty means
    clear. own is a set of PIDs (the service, its server and its client
    tree). The launcher's gpu_clients finds game clients by nvidia-smi and
    by process name, and compute jobs by name; this adds every other
    nvidia-smi compute user that is not a desktop program, and the kernel
    log's driver faults."""
    found = []
    # A software run (a test of the service itself) opens no GPU device, so
    # only the test mode's fake users below can make it yield.
    for pid, name in ([] if software else gh.gpu_clients()):
        if pid in own:
            continue
        args = proc_args(pid)
        # Godot's own --headless driver has a dummy renderer and opens no
        # device: the portal and form tests run that way, under no lock.
        if "--headless" in args and "gamescope" not in name.lower():
            continue
        found.append("%s pid %d" % (name, pid))
    if shutil.which("nvidia-smi") and not software:
        try:
            out = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,process_name",
                                  "--format=csv,noheader"], capture_output=True, text=True,
                                 timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        listed = {int(f.split()[-1]) for f in found if f.split()[-1].isdigit()}
        for line in out.strip().splitlines():
            pid_s, _, name = line.partition(",")
            try:
                pid = int(pid_s)
            except ValueError:
                continue
            base = os.path.basename((name.strip().split() or [""])[0]).lower()
            if pid in own or pid in listed or any(d in base for d in DESKTOP_GPU_USERS):
                continue
            found.append("%s pid %d (nvidia-smi compute)" % (name.strip(), pid))
    errors = [] if software else gh.driver_errors()
    if errors:
        found.append("NVIDIA driver logged %d errors in 30 minutes (last: %s)"
                     % (len(errors), errors[-1][-160:]))
    # Test mode: a file of "pid,name" lines standing in for nvidia-smi
    # compute rows, counted while that PID is alive.
    if fake_file and pathlib.Path(fake_file).exists():
        for line in pathlib.Path(fake_file).read_text().splitlines():
            pid_s, _, name = line.partition(",")
            try:
                pid = int(pid_s)
            except ValueError:
                continue
            if gh.proc_start(pid) is not None and pid not in own:
                found.append("%s pid %d (from the fake nvidia-smi file %s)"
                             % (name.strip() or "python", pid, fake_file))
    return found


# --- builds, packs and profiles ----------------------------------------------

def resolve_build(path):
    """A checkout or worktree whose project/bin holds a built extension."""
    root = pathlib.Path(path).expanduser().resolve() if path else main_checkout()
    if (root / "project.godot").exists():
        root = root.parent
    project = root / "project"
    if not (project / "project.godot").exists():
        raise RenderError("%s is not a Goanna checkout or worktree" % root)
    lib = project / "bin" / "libgoanna.linux.template_debug.x86_64.so"
    if not lib.exists():
        raise RenderError("%s has no built extension (%s); build it first "
                          "(tools/release/build-goanna-extension.sh)" % (root, lib))
    # An empty luanti/ submodule leaves blank.png missing, and players then
    # draw yellow: refuse rather than photograph that.
    if not (root / "luanti" / "textures" / "base" / "pack" / "blank.png").exists():
        raise RenderError("%s has an empty luanti/ submodule (no blank.png, players would "
                          "draw yellow); run git submodule update --init luanti" % root)
    return root


_hash_cache = {}


def lib_fingerprint(root):
    lib = root / "project" / "bin" / "libgoanna.linux.template_debug.x86_64.so"
    st = lib.stat()
    key = (str(lib), st.st_size, st.st_mtime_ns)
    if key not in _hash_cache:
        h = hashlib.sha256()
        with open(lib, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        _hash_cache[key] = h.hexdigest()[:16]
    return {"lib": str(lib), "sha256": _hash_cache[key], "bytes": st.st_size,
            "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime))}


def git_state(root):
    out = {}
    try:
        out["head"] = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root,
                                     capture_output=True, text=True, timeout=20).stdout.strip()
        out["branch"] = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root,
                                       capture_output=True, text=True,
                                       timeout=20).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"],
                               cwd=root, capture_output=True, text=True, timeout=30).stdout
        files = sorted(l[3:] for l in dirty.splitlines() if l.strip())
        out["dirty"] = bool(files)
        out["dirty_files"] = files[:50]
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def tier_tables(root):
    """PROFILES out of the build's own graphics_profiles.gd, as
    tools/bench/check-bench-plans.py reads it."""
    text = (root / "project" / "graphics_profiles.gd").read_text()
    start = text.index("const PROFILES")
    end = text.index("const ORDER", start) if "const ORDER" in text[start:] else len(text)
    out = {}
    for tier in re.finditer(r'"(\w+)":\s*\{(.*?)\},\n', text[start:end], re.S):
        out[tier.group(1)] = {k: float(v) for k, v in
                              re.findall(r'"(\w+)":\s*(-?[\d.]+)', tier.group(2))}
    if not out:
        raise RenderError("could not read PROFILES from %s" % root)
    return out


def ensure_imported(root, godot, logdir):
    """A worktree that has never been opened has no .godot/ import cache,
    and a client started on it fails to load its scripts. Godot's own
    --headless renders nothing, so this needs no GPU."""
    project = root / "project"
    if (project / ".godot" / "imported").is_dir():
        return 0.0
    log("importing", project, "(first use of this checkout)")
    t0 = time.time()
    with open(logdir / "import.log", "ab") as out:
        subprocess.run([godot, "--headless", "--audio-driver", "Dummy", "--path", str(project),
                        "--import"], stdout=out, stderr=subprocess.STDOUT, timeout=1800,
                       stdin=subprocess.DEVNULL)
    return time.time() - t0


def write_profile(xdg, tier, table, pack, maps):
    cfg_dir = xdg / "godot" / "app_userdata" / "Goanna"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    lines = ["[settings]", "", 'graphics_profile="%s"' % tier,
             'texture_pack="%s"' % (pack or ""), "show_body=0", "asset_updates=false"]
    values = dict(table)
    if not maps:
        values["auto_bump"] = 0.0
    lines += ["%s=%s" % (k, v) for k, v in sorted(values.items())]
    path = cfg_dir / "goanna.cfg"
    path.write_text("\n".join(lines) + "\n")
    return path


# --- the server --------------------------------------------------------------

def free_udp_port(start=30960, span=40):
    for port in range(start, start + span):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                continue
        return port
    raise RenderError("no free UDP port from %d to %d" % (start, start + span - 1))


def game_info(game):
    conf = GAMES / game / "game.conf"
    out = {"id": game}
    try:
        for line in conf.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() in ("title", "version", "release", "author"):
                out[key.strip()] = value.strip()
    except OSError:
        pass
    return out


class Server:
    def __init__(self, game, world_from, stage, floor, logdir, far=False):
        self.game = game
        self.far = far
        self.world_from = world_from
        self.stage = stage
        self.floor = floor
        self.logdir = logdir
        self.proc = None
        self.port = None
        self.world = None
        self.version = ""

    def build_world(self):
        if not (GAMES / self.game / "game.conf").exists():
            raise RenderError("no game '%s' under %s" % (self.game, GAMES))
        if self.world_from:
            src = WORLDS / self.world_from
            if not (src / "world.mt").exists():
                raise RenderError("no world '%s' under %s" % (self.world_from, WORLDS))
            world = WORLDS / ("goanna_render_copy_" + self.world_from)
            if world.exists():
                shutil.rmtree(world)
            subprocess.run(["cp", "-a", "--reflink=auto", str(src), str(world)], check=True)
            mt = (world / "world.mt").read_text()
            m = re.search(r"^gameid\s*=\s*(\S+)", mt, re.M)
            if m and m.group(1) != self.game:
                raise RenderError("world %s is %s, not %s" % (self.world_from, m.group(1),
                                                            self.game))
        else:
            world = WORLDS / ("goanna_render_" + self.game)
            if world.exists():
                shutil.rmtree(world)
            world.mkdir(parents=True)
            (world / "world.mt").write_text(
                "gameid = %s\nbackend = sqlite3\nplayer_backend = sqlite3\n"
                "auth_backend = sqlite3\nmod_storage_backend = sqlite3\n"
                "creative_mode = true\nenable_damage = false\nserver_announce = false\n"
                % self.game)
        mods = world / "worldmods"
        for name in ("goanna_render_fixture", "goanna_server_mod"):
            if (mods / name).exists():
                shutil.rmtree(mods / name)
        fixture = mods / "goanna_render_fixture"
        fixture.mkdir(parents=True)
        (fixture / "mod.conf").write_text(
            "name = goanna_render_fixture\n"
            "description = Goanna render service fixture (its own world only)\n")
        shutil.copyfile(HERE / "render-fixture.lua", fixture / "init.lua")
        # A fresh copy every time: a worldmods copy goes stale whenever the
        # mod changes, and the far field then silently does nothing.
        shutil.copytree(REPO / "goanna_server_mod", mods / "goanna_server_mod")
        self.world = world
        return world

    def write_conf(self):
        s = self.stage
        conf = service_home(self.world) / "server.conf"
        lines = {
            "default_privs": "interact,shout,teleport,fly,fast,give,settime,debug,noclip,"
                             "weather_manager",
            "enable_damage": "false", "creative_mode": "true", "server_announce": "false",
            "bind_address": "127.0.0.1", "time_speed": "0",
            "mg_name": "singlenode",
            # Mineclonia otherwise runs its own Lua level generator in a
            # singlenode world, which built floating terrain over the
            # stage floor on the first trial run.
            "mcl_singlenode_mapgen": "false",
            # At the parking place, so the stage's blocks are first sent
            # when a job arrives rather than held from the client's start.
            "static_spawnpoint": "(%d,%d,%d)" % tuple(s[i] + HOME_OFFSET[i] for i in range(3)),
            "max_block_send_distance": "16",
            # Poses move the player by thousands of nodes a second as far
            # as movement anticheat can tell; it then resets the position
            # and the server streams blocks around the wrong place, which
            # happened on the first trial run ("moved too fast").
            "anticheat_flags": "digging,interaction",
            "max_simultaneous_block_sends_per_client": "64",
            # Mineclonia changes the weather by itself between shots; a
            # storm arrived part way through the 2026-10-05 run.
            "mcl_doWeatherCycle": "false", "mobs_spawn": "false",
            # The service places nodes and statues over chat.
            "chat_message_limit_per_10sec": "100000", "chat_message_max_size": "65535",
            # The far field is off on the fixture, which has nothing past the
            # stage. On the first GPU run (2026-10-06) it kept the client
            # from settling (lod_storage_* never stayed at zero, so every
            # pose waited out its 60 s), and after the player came back from
            # parking only five of the stage's blocks had near meshes: the
            # rest had been handed to the far renderer when pruned.
            "goanna_far_rendering": "true" if self.far else "false",
            "goanna_far_rendering_distance": "512",
            "goanna_render_stage": "(%d,%d,%d)" % s,
            "goanna_render_floor": self.floor or "",
        }
        conf.write_text("".join("%s = %s\n" % kv for kv in lines.items()))
        return conf

    def start(self):
        self.build_world()
        conf = self.write_conf()
        self.port = free_udp_port()
        try:
            self.version = subprocess.run(FLATPAK + ["--version"], capture_output=True,
                                          text=True, timeout=60).stdout.splitlines()[0]
        except (OSError, subprocess.SubprocessError, IndexError):
            self.version = "unknown"
        debug = service_home(self.world) / "server-debug.log"
        debug.unlink(missing_ok=True)
        out = open(self.logdir / "server.log", "wb")
        self.proc = subprocess.Popen(
            FLATPAK + ["--server", "--world", str(self.world), "--port", str(self.port),
                       "--config", str(conf), "--logfile", str(debug)],
            stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            start_new_session=True)
        out.close()
        log("server pid", self.proc.pid, "port", self.port, "world", self.world)
        deadline = time.time() + 180
        floor_ok = False
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RenderError("the server exited (%d); see %s"
                                  % (self.proc.returncode, self.logdir / "server.log"))
            text = ""
            for path in (self.logdir / "server.log", debug):
                try:
                    text += path.read_text(errors="replace")
                except OSError:
                    pass
            if "GOANNA_RENDER_STAGE_READY" in text and "listening on" in text.lower():
                floor_ok = True
                break
            time.sleep(0.5)
        if not floor_ok:
            raise RenderError("the server never laid the stage; see %s" % debug)

    def pids(self):
        if not self.proc:
            return set()
        return {self.proc.pid} | set(gh.descendants(self.proc.pid))

    def player_online(self, name=PLAYER):
        """Whether the server still counts the player as connected. A client
        stopped over the control channel can leave its peer behind until it
        times out, and the next client under the same name is refused."""
        try:
            text = (service_home(self.world) / "server-debug.log").read_text(errors="replace")
        except OSError:
            return False
        joins = len(re.findall(r"\b%s \[[^\]]*\] joins game" % re.escape(name), text))
        leaves = len(re.findall(r"\b%s (leaves game|times out)" % re.escape(name), text))
        return joins > leaves

    def stop(self):
        if not self.proc:
            return
        # Only this server's own process tree, found from the PID started here.
        tree = [(p, gh.proc_start(p)) for p in gh.descendants(self.proc.pid)]
        tree.append((self.proc.pid, gh.proc_start(self.proc.pid)))
        for pid, start in tree:
            if gh.alive(pid, start):
                gh.signal_pid(pid, signal.SIGTERM)
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            pass
        if not gh.wait_gone(tree, 15):
            for pid, start in tree:
                if gh.alive(pid, start):
                    gh.signal_pid(pid, signal.SIGKILL)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        log("server stopped")
        self.proc = None


# --- the client --------------------------------------------------------------

class Client:
    """One headless Goanna client, launched through goanna_headless with a
    profile written for its launch key and read back once it is up."""

    def __init__(self, logdir, server, software=False, gpu_lock=None):
        self.server = server
        # The service's own GpuLock. goanna_headless takes the lock itself
        # for a GPU start and would refuse this one as busy, so it is handed
        # the descriptor the service already holds.
        self.gpu_lock = gpu_lock
        server_port = server.port
        self.software = software
        self.logdir = logdir
        self.server_port = server_port
        self.rec = None
        self.key = None
        self.control = None
        self.info = {}
        self.launches = 0

    def pids(self):
        if not self.rec:
            return set()
        out = set()
        for k in ("supervisor_pid", "gamescope_pid", "child_pid"):
            if self.rec.get(k):
                out.add(int(self.rec[k]))
        if self.rec.get("supervisor_pid"):
            out |= set(gh.descendants(int(self.rec["supervisor_pid"])))
        return out

    def running(self):
        if not self.rec:
            return False
        rec = gh.load(self.rec["id"])
        return rec.get("status") == "running" and gh.alive(rec.get("child_pid"),
                                                           rec.get("child_start"))

    def stop(self):
        if self.control:
            self.control.close()
            self.control = None
        if self.rec:
            try:
                out = gh.stop(self.rec["id"])
                log("client stopped", json.dumps(out))
            except gh.LaunchError as exc:
                log("client stop:", exc)
        self.rec = None
        self.key = None

    def launch(self, key, spec, own_pids, fake_file):
        """Start a client for spec (a resolved launch spec). Returns the
        seconds it took."""
        busy = foreign_gpu_users(own_pids | self.pids(), fake_file, self.software)
        if busy:
            raise Yield("; ".join(busy))
        self.stop()
        t0 = time.time()
        # The last client's player has to be gone from the server first.
        deadline = time.time() + 60
        while self.server.player_online() and time.time() < deadline:
            time.sleep(1.0)
        root = spec["build_root"]
        if CALLER_GODOT_BIN is None:
            os.environ.pop("GODOT_BIN", None)
        else:
            os.environ["GODOT_BIN"] = CALLER_GODOT_BIN
        godot = gh.find_godot(root / "project")
        import_s = ensure_imported(root, godot, self.logdir)
        self.launches += 1
        # A fresh directory, so a fresh profile, every launch.
        launch_dir = self.logdir / ("launch-%s-%02d" % (time.strftime("%H%M%S"), self.launches))
        launch_dir.mkdir(parents=True, exist_ok=True)
        wrapper = launch_dir / "godot-dummy-audio"
        wrapper.write_text('#!/bin/sh\nexec %s --audio-driver Dummy "$@"\n' % godot)
        wrapper.chmod(0o755)
        os.environ["GODOT_BIN"] = str(wrapper)
        xdg = launch_dir / "xdg"
        cfg = write_profile(xdg, spec["tier"], spec["tier_table"], spec["pack"], spec["maps"])
        env = {"XDG_DATA_HOME": str(xdg), "GOANNA_BENCH": "1", "GOANNA_NO_HW_DEFAULTS": "1",
               "GOANNA_PACK": spec["pack"] or "", "GOANNA_PACK_SET": "1",
               "GOANNA_DEBUG_ENTITY_PBR": "1", "GOANNA_PBR_SET": "1",
               "GOANNA_NO_PBR": "" if spec["maps"] else "1"}
        if not spec["maps"]:
            # Maps off is the art alone: no pack companions and no relief
            # inferred from brightness. GOANNA_AUTO_BUMP pins it, so a
            # profile cannot put the inference back.
            env["GOANNA_AUTO_BUMP"] = "0"
        env.update(spec["env"])
        w, h = spec["size"]
        for attempt in range(2):
            try:
                self.rec = gh.start_goanna(root, control_port=None, port=self.server_port,
                                           name=PLAYER, width=w, height=h, env=env,
                                           software=self.software,
                                           label="render service", cpu_compositor=True,
                                           gpu_lock_fd=(self.gpu_lock.fd if self.gpu_lock
                                                        else None),
                                           ready_timeout=180.0,
                                           meta={"render_service": os.getpid()})
            except gh.LaunchError as exc:
                raise RenderError("client did not start: %s" % exc)
            self.control = Control(self.rec["control_port"])
            try:
                self._wait_ready()
                break
            except RenderError as exc:
                if attempt or "already connected" not in str(exc):
                    raise
                log("the server still holds the last player; waiting and trying again")
                self.stop()
                time.sleep(20.0)
        self.key = key
        self.info = self._verify(spec, cfg)
        self.info.update(import_s=round(import_s, 1), launch_s=round(time.time() - t0, 1),
                         client_log=self.rec.get("client_log"), xdg=str(xdg),
                         control_port=self.rec["control_port"], instance=self.rec["id"])
        log("client up", self.rec["id"], "in %.0fs" % (time.time() - t0),
            "tier", spec["tier"], "maps", spec["maps"], "build", root)
        return time.time() - t0

    def _wait_ready(self, timeout=240.0):
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            st = self.control.send("status")
            last = str(st.get("state", ""))
            if last == "ready":
                return st
            if last == "denied":
                raise RenderError("the server refused the client: %s" % st.get("message"))
            time.sleep(1.0)
        raise RenderError("the client never became ready; still %r" % last)

    def _verify(self, spec, cfg):
        """The stale profile trap: a profile first saved on lavapipe kept Low
        with parallax off and invalidated three GPU reviews. So the adapter
        must be the card, and every value of the tier must read back."""
        c = self.control
        adapter = c.run("return RenderingServer.get_video_adapter_name()")
        on_cpu = not adapter or any(w in str(adapter).lower() for w in ("llvmpipe", "lavapipe"))
        if on_cpu != self.software:
            raise RenderError("the client is rendering on %r, %s" % (
                adapter, "not the GPU" if on_cpu else "not lavapipe as --software asked"))
        held = self.settings()
        wrong = {}
        for key, want in spec["tier_table"].items():
            # far_distance follows the server's far grant (docs/agents/
            # control-channel.md, "Cold verify"), so it is recorded, not required.
            if want < 0 or key == "far_distance":
                continue
            have = held.get(key)
            if have is None or abs(float(have) - want) > 0.001:
                wrong[key] = {"want": want, "have": have}
        if not spec["maps"]:
            ab = held.get("auto_bump")
            if ab is None or float(ab) > 0.0:
                wrong["auto_bump"] = {"want": 0.0, "have": ab}
        if wrong:
            raise RenderError("the profile did not hold (%s): %s" % (cfg, json.dumps(wrong)))
        version = c.run("return Engine.get_version_info().string")
        luanti = c.eval("client.luanti_version()")
        return {"adapter": adapter, "godot": version, "client_luanti": luanti,
                "profile_file": str(cfg), "profile_verified": True}

    def settings(self):
        got = self.control.send("settings")
        return {k: v.get("value") for k, v in got.items() if isinstance(v, dict)}

    def shader_errors(self):
        """Shader compile errors in the client log so far. Godot compiles a
        material's shader when it is first drawn, so a pass that fails shows
        here only after a frame with it in view; a frame with a failed pass
        draws the fallback and can look plausible."""
        try:
            text = pathlib.Path(self.rec["client_log"]).read_text(errors="replace")
        except (OSError, TypeError):
            return []
        lines = text.splitlines()
        out = []
        for i, line in enumerate(lines):
            low = line.lower()
            if "shader error" in low or "shader compilation failed" in low or \
                    ("error" in low and ".gdshader" in low):
                out.append(" | ".join(x.strip() for x in lines[i:i + 3])[:400])
        return out

    def entity_normals(self):
        """Counts of entity materials built with and without a normal map,
        from GOANNA_DEBUG_ENTITY_PBR's log lines."""
        out = {"normal_true": 0, "normal_false": 0, "true_examples": []}
        try:
            text = pathlib.Path(self.rec["client_log"]).read_text(errors="replace")
        except (OSError, TypeError):
            return out
        for line in text.splitlines():
            if "entity pbr:" not in line:
                continue
            if " normal=true" in line:
                out["normal_true"] += 1
                if len(out["true_examples"]) < 5:
                    out["true_examples"].append(line.strip()[:200])
            elif " normal=false" in line:
                out["normal_false"] += 1
        return out


# --- jobs --------------------------------------------------------------------

def to_goanna(p):
    """Luanti coordinates to the ones Goanna's tp, pose, look and
    node_name_at take: z negated."""
    return [float(p[0]), float(p[1]), -float(p[2])]


# Draws without presenting, back to back, on the main thread. Presented
# frame timing under headless gamescope is useless: the client presents
# about 33 frames a second whatever it draws, the GPU idles most of each
# frame at low clocks, and timings swing between 2.8 and 10 ms with nothing
# changed (docs/perf/low-tier-occlusion-2026-10-05/run.py). The world is
# frozen while this runs.
BURST_SRC = """var vp: RID = main.get_viewport().get_viewport_rid()
RenderingServer.viewport_set_measure_render_time(vp, true)
for i in 30:
	RenderingServer.force_draw(false, 0.0)
var out: Array = []
var last := Time.get_ticks_usec()
for i in %d:
	RenderingServer.force_draw(false, 0.0)
	var now := Time.get_ticks_usec()
	out.append([(now - last) / 1000.0, RenderingServer.viewport_get_measured_render_time_cpu(vp),
			RenderingServer.viewport_get_measured_render_time_gpu(vp)])
	last = now
return out"""

CROP_SRC = """var img := Image.load_from_file(%s)
if img == null:
	return "no image"
var r := img.get_region(Rect2i(%d, %d, %d, %d))
return r.save_png(%s)"""


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(q * len(s)))] if s else None


def safe_name(text):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(text)).strip("_") or "x"


class Service:
    def __init__(self, opt):
        self.opt = opt
        self.state = state_dir()
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.logdir = pathlib.Path(os.environ.get("XDG_CACHE_HOME") or
                                   pathlib.Path.home() / ".cache") / "goanna-render" / stamp
        self.logdir.mkdir(parents=True, exist_ok=True)
        self.lock = GpuLock()
        self.server = None
        self.client = None
        self.stop_requested = False
        self.status = "starting"
        self.current = None
        self.last_job = time.time()
        self.started = time.time()
        self.stage = tuple(opt.stage)
        self.default = None
        self.jobs_done = 0
        self.yields = []
        self.restarts = []
        self.floor = opt.floor if opt.floor is not None else FLOORS.get(opt.game, "")

    # --- bookkeeping

    def own_pids(self):
        own = {os.getpid()} | set(gh.descendants(os.getpid()))
        if self.server:
            own |= self.server.pids()
        if self.client:
            own |= self.client.pids()
        return own

    def publish(self, **extra):
        data = {"pid": os.getpid(), "start": gh.proc_start(os.getpid()), "status": self.status,
                "game": self.opt.game, "world_from": self.opt.world_from or "fixture",
                "stage": self.stage, "log_dir": str(self.logdir), "lock": GPU_LOCK,
                "lock_held": self.lock.held(), "current_job": self.current,
                "queue": sorted(p.stem for p in (self.state / "queue").glob("*.json")),
                "jobs_done": self.jobs_done, "idle_minutes": self.opt.idle_minutes,
                "since": self.started, "updated": time.time(), "yields": self.yields[-5:],
                "restarts": self.restarts[-10:],
                "server": {"port": self.server.port, "version": self.server.version,
                           "world": str(self.server.world)} if self.server else None,
                "client": dict(self.client.info, key=self.client.key)
                if self.client and self.client.rec else None,
                "default": self.default_public()}
        data.update(extra)
        write_json(self.state / "service.json", data)

    def default_public(self):
        if not self.default:
            return None
        return {k: (str(v) if isinstance(v, pathlib.Path) else v)
                for k, v in self.default.items() if k != "tier_table"}

    def check_stop(self):
        if self.stop_requested:
            raise RenderError("the service was asked to stop")

    def check_gpu(self):
        busy = foreign_gpu_users(self.own_pids(), self.opt.fake_gpu_user, self.opt.software)
        if busy:
            raise Yield("; ".join(busy))

    # --- bringing it up and down

    def bring_up(self):
        self.status = "waiting for the GPU lock"
        self.publish()
        if self.opt.software:
            log("software rendering: the GPU lock is not taken")
        elif not self.lock.acquire(lambda: self.stop_requested,
                                   lambda: log("waiting for", GPU_LOCK,
                                               "(another agent holds it)")):
            return False
        else:
            log("holding", GPU_LOCK)
        busy = foreign_gpu_users(self.own_pids(), self.opt.fake_gpu_user, self.opt.software)
        if busy:
            raise Yield("; ".join(busy))
        self.status = "starting the server"
        self.publish()
        self.server = Server(self.opt.game, self.opt.world_from, self.stage, self.floor,
                             self.logdir, far=self.opt.far or bool(self.opt.world_from))
        self.server.start()
        self.client = Client(self.logdir, self.server, self.opt.software, self.lock)
        self.status = "starting the client"
        self.publish()
        self.ensure_client(self.default)
        self.park()
        self.status = "ready"
        self.publish()
        return True

    def bring_down(self, why):
        log("stopping:", why)
        if self.client:
            self.client.stop()
        if self.server:
            self.server.stop()
        self.client = None
        self.server = None
        self.lock.release()
        log("released", GPU_LOCK)

    def ensure_client(self, spec):
        key = json.dumps({k: (str(v) if isinstance(v, pathlib.Path) else v)
                          for k, v in spec.items() if k in LAUNCH_FIELDS or k == "lib"},
                         sort_keys=True)
        if self.client.key == key and self.client.running():
            return 0.0
        why = "first launch" if self.client.key is None else "launch settings changed"
        if self.client.key is not None and not self.client.running():
            why = "the client had exited"
        secs = self.client.launch(key, spec, self.own_pids(), self.opt.fake_gpu_user)
        self.publish()
        self.restarts.append({"at": now(), "why": why, "seconds": round(secs, 1),
                              "tier": spec["tier"], "maps": spec["maps"],
                              "build": str(spec["build_root"])})
        c = self.client.control
        c.send("fly", {"on": True})
        if self.opt.game in WEATHER_GAMES:
            c.chat("/weather clear 1000000")
        return secs

    def teleport(self, g):
        """A tp with the camera put there first. main.teleport_to waits for
        the blocks to stream in with the camera still where it was and only
        then moves it, and the client tiers what arrives against the
        camera: on the first GPU run (2026-10-06) the stage's blocks came in
        while the camera was 1200 nodes away at the parking place and were
        never meshed (0 to 5 of them, for minutes), so the frames were sky.
        A pose first moves the camera and the player together."""
        c = self.client.control
        c.send("pose", {"x": g[0], "y": g[1], "z": g[2], "fly": True})
        return c.send("tp", {"x": g[0], "y": g[1], "z": g[2]})

    def park(self):
        c = self.client.control
        home = [self.stage[i] + HOME_OFFSET[i] for i in range(3)]
        c.send("fly", {"on": True})
        try:
            self.teleport([home[0], home[1], -home[2]])
        except RenderError as exc:
            log("park:", exc)

    # --- the loop

    def serve(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, self._on_signal)
        self._code_stamp = code_stamp()
        self.default = self.resolve_launch({})
        try:
            while not self.stop_requested:
                try:
                    if not self.server:
                        if not self.bring_up():
                            break
                    self.loop()
                except Yield as exc:
                    self.yield_gpu(str(exc))
        except Exception as exc:  # noqa: BLE001 - the reason goes into the status
            self.status = "failed"
            self.publish(reason=str(exc))
            log("failed:", exc)
            self.bring_down("failure: %s" % exc)
            self.fail_running("the service failed: %s" % exc)
            raise
        finally:
            if self.server or self.lock.held():
                self.bring_down("stop requested" if self.stop_requested else "exit")
        self.status = "stopped"
        self.publish()
        self.fail_running("the service stopped")
        return 0

    def _on_signal(self, signum, frame):
        log("signal", signum)
        self.stop_requested = True

    def yield_gpu(self, why):
        log("yielding the GPU:", why)
        self.yields.append({"at": now(), "why": why})
        if self.current:
            # Back to the front of the queue: it runs again when the card
            # is clear, from the start.
            src = self.state / "running" / (self.current + ".json")
            if src.exists():
                src.replace(self.state / "queue" / (self.current + ".json"))
            self.current = None
        self.bring_down("yield: %s" % why)
        self.status = "yielded"
        self.publish(yield_reason=why)
        clear_since = None
        while not self.stop_requested:
            self.reexec_if_changed()
            busy = foreign_gpu_users(self.own_pids(), self.opt.fake_gpu_user, self.opt.software)
            if busy:
                clear_since = None
                self.publish(yield_reason="; ".join(busy))
            elif clear_since is None:
                clear_since = time.time()
            elif time.time() - clear_since >= self.opt.clear_seconds:
                log("the card has been clear for %ds; coming back" % self.opt.clear_seconds)
                return
            if self.idle_expired():
                log("idle while yielded; stopping")
                self.stop_requested = True
                return
            time.sleep(self.opt.poll_seconds)

    def reexec_if_changed(self):
        """A service yielded for hours runs the code it started with. On
        2026-10-06 one kept yielding to lavapipe clients after gpu-free had
        been fixed to ignore them (dec70408), because its copy of
        goanna_headless was the old one. While yielded it holds no client,
        server or lock, so it can start again in place: the queue is on
        disk and the job it was running is back at the front."""
        if getattr(self, "_code_stamp", None) is None:
            return
        if code_stamp() == self._code_stamp:
            return
        log("the service's own code changed while yielded; starting again with it")
        self.status = "restarting"
        self.publish()
        sys.stdout.flush()
        os.execv(sys.executable, [sys.executable, str(pathlib.Path(__file__).resolve()),
                                  "serve"] + list(self.opt.argv))

    def idle_expired(self):
        queued = any((self.state / "queue").glob("*.json"))
        return not queued and time.time() - self.last_job > self.opt.idle_minutes * 60

    def next_job(self):
        for path in sorted((self.state / "queue").glob("*.json")):
            target = self.state / "running" / path.name
            try:
                path.replace(target)
            except OSError:
                continue
            return target
        return None

    def loop(self):
        last_check = 0.0
        while not self.stop_requested:
            if time.time() - last_check >= self.opt.poll_seconds:
                self.check_gpu()
                if not self.client.running():
                    log("the client is gone; relaunching")
                    self.ensure_client(self.default)
                    self.park()
                last_check = time.time()
            job = self.next_job()
            if job is None:
                if self.idle_expired():
                    log("idle for %g minutes; stopping" % self.opt.idle_minutes)
                    self.stop_requested = True
                    return
                time.sleep(0.5)
                continue
            self.check_gpu()
            self.run_job(job)
            last_check = time.time()

    def fail_running(self, why):
        for path in (self.state / "running").glob("*.json"):
            job = read_json(path) or {}
            write_json(self.state / "done" / path.name,
                       {"id": path.stem, "ok": False, "error": why, "out": job.get("out")})
            path.unlink(missing_ok=True)

    # --- one job

    def resolve_launch(self, spec):
        """Fill a job's launch level fields from the service defaults."""
        build = resolve_build(spec.get("build") or self.opt.build)
        tables = tier_tables(build)
        tier = spec.get("tier") or self.opt.tier
        if tier not in tables:
            raise RenderError("no tier '%s'; the build has %s" % (tier, ", ".join(tables)))
        pack = spec.get("pack", None)
        if pack is None:
            pack = self.opt.pack
        if pack is None:
            cand = main_checkout() / "pbr_packs" / self.opt.game / "textures"
            pack = str(cand) if cand.is_dir() else ""
        if pack and not pathlib.Path(pack).is_dir():
            raise RenderError("texture pack %s is not a directory" % pack)
        size = spec.get("size") or self.opt.size
        env = {str(k): str(v) for k, v in (spec.get("env") or {}).items()}
        launch_profile = {k: float(v) for k, v in (spec.get("profile") or {}).items()
                          if k in LAUNCH_PROFILE_KEYS}
        table = dict(tables[tier], **launch_profile)
        return {"build": str(build), "build_root": build, "lib": lib_fingerprint(build)["sha256"],
                "tier": tier, "tier_table": table, "pack": pack,
                "launch_profile": launch_profile,
                "size": [int(size[0]), int(size[1])], "env": env,
                "maps": bool(spec.get("maps", True))}

    def place(self, pos):
        if self.job_frame == "world":
            return [float(v) for v in pos]
        return [float(pos[i]) + self.stage[i] for i in range(3)]

    def run_job(self, path):
        t0 = time.time()
        raw = read_json(path)
        ident = path.stem
        self.current = ident
        result = {"id": ident, "ok": False, "started": now()}
        if raw is None:
            result["error"] = "the job file is not JSON"
            write_json(self.state / "done" / path.name, result)
            path.unlink(missing_ok=True)
            self.current = None
            return
        sub = raw.get("_submitter") or {}
        if sub.get("pid") and not gh.alive(sub.get("pid"), sub.get("start")):
            result["error"] = "abandoned: the shell that submitted it has gone"
            write_json(self.state / "done" / path.name, result)
            path.unlink(missing_ok=True)
            self.current = None
            return
        result["queued_s"] = round(t0 - float(sub.get("queued_at", t0)), 1)
        self.status = "busy"
        self.publish()
        log("job", ident, raw.get("label", ""))
        try:
            result.update(self.shoot(raw, ident))
            result["ok"] = not result.get("problems")
            if result.get("problems"):
                result["error"] = "; ".join(result["problems"])
        except Yield:
            raise
        except Exception as exc:  # noqa: BLE001 - reported to the job's caller
            result["error"] = str(exc)
            log("job", ident, "failed:", exc)
            try:
                self.reset_world()
            except Exception as exc2:  # noqa: BLE001
                log("reset after failure:", exc2)
        result["wall_s"] = round(time.time() - t0, 1)
        result["finished"] = now()
        out = raw.get("out")
        if out:
            try:
                write_json(pathlib.Path(out) / "result.json", result)
            except OSError:
                pass
        write_json(self.state / "done" / path.name, result)
        path.unlink(missing_ok=True)
        self.current = None
        self.jobs_done += 1
        self.last_job = time.time()
        self.status = "ready"
        self.publish()
        log("job", ident, "done in %.0fs" % result["wall_s"], "ok" if result["ok"] else "FAILED")

    def shoot(self, job, ident):
        out = pathlib.Path(job.get("out") or (self.state / "out" / ident)).expanduser()
        out.mkdir(parents=True, exist_ok=True)
        game = job.get("game")
        if game and game != self.opt.game:
            raise RenderError("this service runs %s, not %s; start one for that game"
                              % (self.opt.game, game))
        self.job_frame = job.get("frame", "stage")
        if self.job_frame not in ("stage", "world"):
            raise RenderError("frame is stage or world")
        poses = job.get("poses") or []
        if not poses and not job.get("timing"):
            raise RenderError("a job wants poses")
        for i, p in enumerate(poses):
            p.setdefault("name", "pose%d" % i)
            if "pos" not in p:
                raise RenderError("pose %s has no pos" % p["name"])
        variants = job.get("variants") or [{"name": "default"}]
        base = {k: job[k] for k in ("build", "pack", "tier", "size", "env", "maps", "profile",
                                    "time", "weather") if k in job}
        resolved = []
        for i, v in enumerate(variants):
            v = dict(v)
            v.setdefault("name", "v%d" % i)
            merged = dict(base)
            for k, val in v.items():
                if k in ("env", "profile") and isinstance(val, dict):
                    merged[k] = dict(base.get(k) or {}, **val)
                else:
                    merged[k] = val
            launch = self.resolve_launch(merged)
            resolved.append((v["name"], merged, launch))
        # Variants that share a launch run together, so a job with maps on
        # and off restarts the client once, not once per pose.
        groups = []
        for name, merged, launch in resolved:
            key = json.dumps({k: str(launch[k]) for k in LAUNCH_FIELDS + ("lib",)},
                             sort_keys=True)
            for g in groups:
                if g["key"] == key:
                    g["variants"].append((name, merged))
                    break
            else:
                groups.append({"key": key, "launch": launch, "variants": [(name, merged)]})
        problems = []
        frames = []
        timing = {}
        restarts = []
        self.place_world(job)
        try:
            for g in groups:
                self.check_stop()
                self.check_gpu()
                secs = self.ensure_client(g["launch"])
                if secs:
                    restarts.append({"seconds": round(secs, 1), "tier": g["launch"]["tier"],
                                     "maps": g["launch"]["maps"],
                                     "build": g["launch"]["build"]})
                self.arrive(job, problems)
                if job.get("frames", True) and poses:
                    for name, merged in g["variants"]:
                        self.check_stop()
                        self.check_gpu()
                        frames += self.shoot_variant(job, out, name, merged, g["launch"],
                                                     poses, problems)
                if job.get("timing"):
                    timing.update(self.time_group(job, out, g, poses))
        finally:
            self.reset_world()
        return {"out": str(out), "frames": frames, "timing": timing, "client_restarts": restarts,
                "problems": problems,
                "variants_order": [n for g in groups for n, _ in g["variants"]]}

    def place_world(self, job):
        c = self.client.control
        sent = 0
        for n in job.get("nodes") or []:
            if "box" in n:
                a, b = self.place(n["box"][0]), self.place(n["box"][1])
            else:
                a = b = self.place(n["pos"])
            extra = ""
            if n.get("param2") is not None:
                extra += " %d" % int(n["param2"])
            if n.get("swap"):
                extra += " swap"
            said, refused = c.chat("/rs_box %d %d %d %d %d %d %s%s" % (
                round(a[0]), round(a[1]), round(a[2]), round(b[0]), round(b[1]), round(b[2]),
                n["node"], extra), expect="rs_box")
            if refused or not any("rs_box queued" in s for s in said):
                raise RenderError("placing %s failed: %s" % (n, said))
            sent += 1
        if sent:
            deadline = time.time() + 120
            while time.time() < deadline:
                said, _ = c.chat("/rs_status", expect="rs_status")
                m = re.search(r"pending=(\d+)", " ".join(said))
                if m and m.group(1) == "0":
                    break
                time.sleep(0.5)
            else:
                raise RenderError("the server never finished placing the job's nodes")
        # Lua chunks after the boxes, so they can set meta on placed nodes.
        for i, src in enumerate(job.get("lua") or []):
            if isinstance(src, list):
                src = "\n".join(src)
            said, refused = c.chat("/rs_lua " + base64.b64encode(src.encode()).decode(),
                                   expect="rs_lua")
            if refused or not any("rs_lua ok" in x for x in said):
                raise RenderError("lua chunk %d failed: %s" % (i, said))
        for s in job.get("statues") or []:
            p = self.place(s["pos"])
            body = dict(s, pos=p, yaw=float(s.get("yaw", 0)))
            said, refused = c.chat("/rs_statue_json " + base64.b64encode(
                json.dumps(body).encode()).decode(), expect="rs_statue")
            if refused or not any("rs_statue" in x and " at " in x for x in said):
                raise RenderError("statue %s failed: %s" % (s, said))

    def checks_for(self, job):
        """Node lookups that say the area has reached the client: every
        corner of every box, and the job's own verify list."""
        checks = []
        for n in job.get("nodes") or []:
            if "box" in n:
                a, b = n["box"]
                corners = {(x, y, z) for x in (a[0], b[0]) for y in (a[1], b[1])
                           for z in (a[2], b[2])}
            else:
                corners = {tuple(n["pos"])}
            for p in sorted(corners):
                checks.append({"pos": list(p), "node": n["node"]})
        for v in job.get("verify") or []:
            checks.append({"pos": v["pos"], "node": v["node"]})
        return checks

    def look_up(self, checks):
        c = self.client.control
        out = []
        for chk in checks:
            g = to_goanna(self.place(chk["pos"]))
            have = c.eval("client.node_name_at(Vector3(%f, %f, %f))" % tuple(g))
            out.append(dict(chk, have=have, ok=have == chk["node"]))
        return out

    def statue_check(self, job):
        # lua_statues: ones a Lua chunk made with statue(), checked alike.
        statues = (job.get("statues") or []) + (job.get("lua_statues") or [])
        if not statues:
            return []
        ents = self.client.control.eval("client.entity_list()") or []
        out = []
        for s in statues:
            g = to_goanna(self.place(s["pos"]))
            hit = None
            for e in ents:
                pos = e.get("position")
                if isinstance(pos, str):
                    nums = [float(x) for x in re.findall(r"-?[\d.]+", pos)]
                else:
                    nums = list(pos or [])
                if e.get("name") == s["entity"] and len(nums) == 3 and \
                        sum((nums[i] - g[i]) ** 2 for i in range(3)) < 2.5 ** 2:
                    hit = e.get("id")
            out.append({"entity": s["entity"], "pos": s["pos"], "ok": hit is not None, "id": hit})
        return out

    def arrive(self, job, problems):
        """One teleport to the job's anchor, then camera poses only. After a
        run of teleports between poses the near mesh of one map block went
        missing for the rest of a session (2026-10-05), so poses are camera
        moves and the area is checked by node lookups before any frame."""
        c = self.client.control
        anchor = job.get("anchor") or (job.get("poses") or [{"pos": [0, 2, -6]}])[0]["pos"]
        g = to_goanna(self.place(anchor))
        c.send("fly", {"on": True})
        self.teleport(g)
        # The server's answer to a tp can land after a pose and carry the
        # camera off with the player.
        time.sleep(3.0)
        c.send("wait", {"settle": True})
        checks = self.checks_for(job)
        for attempt in range(3):
            deadline = time.time() + 30
            while True:
                looked = self.look_up(checks)
                statues = self.statue_check(job)
                # Node data is not meshes: the first GPU run had every lookup
                # right and nothing drawn. The fixture's floor alone meshes.
                meshed = int(c.send("status").get("blocks_meshed", 0))
                if all(x["ok"] for x in looked) and all(s["ok"] for s in statues) and \
                        (meshed > 0 or self.job_frame == "world"):
                    self.node_checks = {"nodes": looked, "statues": statues,
                                        "attempts": attempt + 1, "blocks_meshed": meshed}
                    return
                if time.time() > deadline:
                    break
                time.sleep(1.0)
            # The client holds blocks without the edits: go far away so they
            # are dropped, and come back for fresh ones.
            log("area not as placed (attempt %d); leaving and coming back" % (attempt + 1))
            self.park()
            time.sleep(3.0)
            self.teleport(g)
            time.sleep(3.0)
            c.send("wait", {"settle": True})
        self.node_checks = {"nodes": looked, "statues": statues, "attempts": 3}
        bad = [x for x in looked if not x["ok"]] + [s for s in statues if not s["ok"]]
        problems.append("the area never matched the job after 3 arrivals: %s"
                        % json.dumps(bad[:6]))

    def apply_live(self, merged):
        """Profile overrides, time and weather, applied live. Returns what
        to put back."""
        c = self.client.control
        held = self.client.settings()
        undo = {}
        for key, value in (merged.get("profile") or {}).items():
            if key in LAUNCH_PROFILE_KEYS:
                continue
            if key not in held:
                raise RenderError("'%s' is not a client setting" % key)
            undo.setdefault(key, held[key])
            c.send("set", {"key": key, "value": float(value)})
            c.send("wait", {"frames": 5})
        tod = merged.get("time", 0.5)
        c.send("time", {"tod": float(tod), "server": True})
        weather = merged.get("weather", "clear")
        if self.opt.game in WEATHER_GAMES:
            said, refused = c.chat("/weather %s 1000000" % weather)
            if refused:
                raise RenderError("weather %s refused: %s" % (weather, said))
        elif weather not in (None, "clear"):
            raise RenderError("this service's game has no weather command")
        c.send("wait", {"frames": 30})
        return undo

    def put_back(self, undo):
        c = self.client.control
        for key, value in undo.items():
            c.send("set", {"key": key, "value": float(value)})

    def pose(self, p):
        c = self.client.control
        g = to_goanna(self.place(p["pos"]))
        args = {"x": g[0], "y": g[1], "z": g[2], "fly": True}
        if "look_at" not in p:
            args["yaw"] = float(p.get("yaw", 0.0))
            args["pitch"] = float(p.get("pitch", 0.0))
        c.send("pose", args)
        if "look_at" in p:
            t = to_goanna(self.place(p["look_at"]))
            c.send("look", {"x": t[0], "y": t[1], "z": t[2]})
        c.send("wait", {"settle": True})
        t0 = time.time()
        self.settled = {"quiet": self.wait_quiet(3.0, 60.0), "waited_s": round(time.time() - t0, 1)}

    def wait_quiet(self, quiet, timeout):
        c = self.client.control
        deadline = time.time() + timeout
        since = None
        while time.time() < deadline:
            state = c.eval("bench._settle_since")
            if state is not None and float(state) >= 0.0:
                since = since or time.time()
                if time.time() - since >= quiet:
                    return True
            else:
                since = None
            time.sleep(0.5)
        return False

    def sidecar_common(self, launch, merged, held):
        build = launch["build_root"]
        info = self.client.info
        return {
            "build": dict(lib_fingerprint(build), checkout=str(build), **git_state(build)),
            "versions": {"godot": info.get("godot"), "client_luanti": info.get("client_luanti"),
                         "server": self.server.version, "game": game_info(self.opt.game)},
            "adapter": info.get("adapter"),
            "profile": {"tier": launch["tier"], "file": info.get("profile_file"),
                        "verified_at_launch": info.get("profile_verified"),
                        "overrides": merged.get("profile") or {},
                        "held": {k: held.get(k) for k in sorted(set(launch["tier_table"]) |
                                                                set(merged.get("profile") or {}) |
                                                                {"auto_bump", "fov"})}},
            "maps": launch["maps"], "pack": launch["pack"], "env": launch["env"],
            "size": launch["size"],
            "time": merged.get("time", 0.5), "weather": merged.get("weather", "clear"),
            "stage": self.stage, "frame": self.job_frame,
            "service": {"pid": os.getpid(), "log_dir": str(self.logdir),
                        "client_instance": info.get("instance")},
        }

    def shoot_variant(self, job, out, name, merged, launch, poses, problems):
        c = self.client.control
        undo = self.apply_live(merged)
        frames = []
        try:
            held = self.client.settings()
            common = self.sidecar_common(launch, merged, held)
            fov_held = held.get("fov")
            for p in poses:
                self.check_stop()
                self.check_gpu()
                if "fov" in p:
                    c.send("set", {"key": "fov", "value": float(p["fov"])})
                self.pose(p)
                shot = out / safe_name(name) / ("%s.png" % safe_name(p["name"]))
                shot.parent.mkdir(parents=True, exist_ok=True)
                meta = c.send("shot", {"path": str(shot), "warm": int(job.get("warm", 20))})
                diag = c.eval('client.material_diagnostics("")') or {}
                normals = self.client.entity_normals()
                shader_errors = self.client.shader_errors()
                if shader_errors:
                    problems.append("%d shader errors in the client log by %s/%s, first: %s"
                                    % (len(shader_errors), name, p["name"], shader_errors[0]))
                side = dict(common)
                side.update({"job": job.get("label", ""), "variant": name, "pose": p,
                             "pose_luanti": self.place(p["pos"]),
                             "pose_goanna": to_goanna(self.place(p["pos"])),
                             "frame_file": str(shot), "client_shot": meta,
                             "node_checks": getattr(self, "node_checks", None),
                             "materials": {k: diag.get(k) for k in
                                           ("pbr_disabled", "materials", "built",
                                            "texture_path") if isinstance(diag, dict)},
                             "entity_normals": normals, "settled": getattr(self, "settled", None),
                             "shader_errors": shader_errors[:20],
                             "taken": now()})
                if p.get("fov") is not None:
                    side["profile"] = dict(side["profile"], held=dict(side["profile"]["held"],
                                                                     fov=float(p["fov"])))
                if not launch["maps"] and normals["normal_true"]:
                    problems.append("maps off, but %d entity materials were built with a "
                                    "normal map" % normals["normal_true"])
                    side["maps_off_verified"] = False
                elif not launch["maps"]:
                    side["maps_off_verified"] = True
                crops = []
                for cr in job.get("crops") or []:
                    x, y, w, h = [int(v) for v in cr["rect"]]
                    dest = shot.with_name("%s.%s.png" % (shot.stem, safe_name(cr["name"])))
                    err = c.run(CROP_SRC % (gd_string(shot), x, y, w, h, gd_string(dest)))
                    if err not in (0, "0"):
                        problems.append("crop %s of %s: %s" % (cr["name"], shot, err))
                    crops.append(str(dest))
                side["crops"] = crops
                write_json(shot.with_suffix(".settings.json"), side)
                frames.append({"variant": name, "pose": p["name"], "path": str(shot),
                               "settings": str(shot.with_suffix(".settings.json")),
                               "crops": crops})
                if "fov" in p and fov_held is not None:
                    c.send("set", {"key": "fov", "value": float(fov_held)})
        finally:
            self.put_back(undo)
        return frames

    def time_group(self, job, out, group, poses):
        """Back to back force_draw bursts per pose, the variants of one
        launch taken in rotation so drift lands on each alike."""
        c = self.client.control
        spec = job["timing"]
        rounds = int(spec.get("rounds", 6))
        draws = int(spec.get("burst", 600))
        names = spec.get("poses") or [p["name"] for p in poses]
        by_name = {p["name"]: p for p in poses}
        variants = group["variants"]
        results = {}
        for pname in names:
            if pname not in by_name:
                raise RenderError("timing pose %s is not among the poses" % pname)
            p = by_name[pname]
            for r in range(rounds):
                order = variants[r % len(variants):] + variants[:r % len(variants)]
                for vname, merged in order:
                    self.check_stop()
                    self.check_gpu()
                    undo = self.apply_live(merged)
                    try:
                        if "fov" in p:
                            c.send("set", {"key": "fov", "value": float(p["fov"])})
                        self.pose(p)
                        time.sleep(float(spec.get("warm_s", 2.0)))
                        rows = c.run(BURST_SRC % draws, timeout=900)
                    finally:
                        self.put_back(undo)
                    gpu = [float(row[2]) for row in rows]
                    cpu = [float(row[1]) for row in rows]
                    run_dir = out / "timing" / safe_name(vname) / safe_name(pname)
                    run_dir.mkdir(parents=True, exist_ok=True)
                    with open(run_dir / ("round-%02d.csv" % r), "w") as f:
                        f.write("frame_ms,cpu_ms,gpu_ms\n")
                        for wall, cp, gp in rows:
                            f.write("%.4f,%.4f,%.4f\n" % (wall, cp, gp))
                    results.setdefault(vname, {}).setdefault(pname, []).append(
                        {"round": r, "gpu_median_ms": statistics.median(gpu),
                         "gpu_p95_ms": pct(gpu, 0.95), "cpu_median_ms": statistics.median(cpu),
                         "draws": len(rows)})
        summary = {}
        for vname, per_pose in results.items():
            for pname, runs in per_pose.items():
                meds = [x["gpu_median_ms"] for x in runs]
                p95s = [x["gpu_p95_ms"] for x in runs]
                summary["%s/%s" % (vname, pname)] = {
                    "gpu_median_ms": round(statistics.median(meds), 4),
                    "median_range": [round(min(meds), 4), round(max(meds), 4)],
                    "gpu_p95_ms": round(statistics.median(p95s), 4),
                    "p95_range": [round(min(p95s), 4), round(max(p95s), 4)],
                    "rounds": len(runs), "draws_per_round": draws}
        held = self.client.settings()
        record = {"summary": summary, "runs": results, "method":
                  "force_draw bursts of %d draws after 30 warm draws, %d rounds, variants "
                  "rotated per round; median and p95 of per draw GPU time" % (draws, rounds),
                  "settings": self.sidecar_common(group["launch"], variants[0][1], held)}
        timing_file = out / "timing" / "timing.json"
        timing_file.parent.mkdir(parents=True, exist_ok=True)
        if timing_file.exists():
            old = read_json(timing_file) or {}
            record["summary"] = dict(old.get("summary") or {}, **summary)
            record["runs"] = dict(old.get("runs") or {}, **results)
        write_json(timing_file, record)
        return summary

    def reset_world(self):
        if not self.client or not self.client.control:
            return
        c = self.client.control
        said, _ = c.chat("/rs_reset", expect="rs_reset")
        log("reset:", " ".join(said))
        c.send("time", {"tod": -1})
        c.send("time", {"tod": 0.5, "server": True})
        c.send("time", {"tod": -1})
        if self.opt.game in WEATHER_GAMES:
            c.chat("/weather clear 1000000")
        self.park()


# --- the command line --------------------------------------------------------

def service_record():
    rec = read_json(state_dir() / "service.json")
    if rec and gh.alive(rec.get("pid"), rec.get("start")):
        return rec
    return None


def parse_size(text):
    w, _, h = str(text).partition("x")
    return [int(w), int(h)]


def cmd_serve(args):
    import argparse
    ap = argparse.ArgumentParser(prog="goanna-render serve")
    ap.add_argument("--game", default="mineclonia")
    ap.add_argument("--world-from", default=None,
                    help="copy this world instead of building the singlenode fixture")
    ap.add_argument("--stage", default="%d,%d,%d" % DEFAULT_STAGE)
    ap.add_argument("--floor", default=None)
    ap.add_argument("--build", default=None, help="default build; main's checkout if left out")
    ap.add_argument("--pack", default=None)
    ap.add_argument("--tier", default="high")
    ap.add_argument("--size", default="1280x720")
    ap.add_argument("--idle-minutes", type=float, default=20.0)
    ap.add_argument("--poll-seconds", type=float, default=5.0)
    ap.add_argument("--clear-seconds", type=float, default=60.0,
                    help="how long the card must be clear before coming back after a yield")
    ap.add_argument("--fake-gpu-user", default=None,
                    help="test mode: a file of pid,name lines treated as nvidia-smi compute rows")
    ap.add_argument("--far", action="store_true",
                    help="grant the far field on the fixture world (always on with --world-from)")
    ap.add_argument("--software", action="store_true",
                    help="render on lavapipe, for testing the service itself; takes no lock")
    ap.add_argument("--foreground", action="store_true")
    opt = ap.parse_args(args)
    opt.argv = [a for a in args if a != "--foreground"] + ["--foreground"]
    opt.stage = [int(v) for v in opt.stage.split(",")]
    opt.size = parse_size(opt.size)
    # A service that reexec_if_changed restarted keeps its pid, so the record
    # it left behind names this very process: that is not a rival.
    rec = service_record()
    if rec and rec.get("pid") != os.getpid():
        print(json.dumps({"error": "a render service is already running",
                          "service": service_record()}, indent=2))
        return 1
    if not opt.foreground:
        st = state_dir()
        (st / "service.json").unlink(missing_ok=True)
        logf = open(st / "service.out", "ab")
        proc = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), "serve",
                                 "--foreground"] + list(args), stdin=subprocess.DEVNULL,
                                stdout=logf, stderr=subprocess.STDOUT, start_new_session=True,
                                close_fds=True)
        deadline = time.time() + 900
        while time.time() < deadline:
            rec = read_json(st / "service.json") or {}
            if rec.get("pid") == proc.pid and rec.get("status") in ("ready", "yielded",
                                                                     "failed", "stopped"):
                print(json.dumps(rec, indent=2))
                return 0 if rec["status"] in ("ready", "yielded") else 1
            if proc.poll() is not None:
                print(json.dumps({"error": "the service exited (%d)" % proc.returncode,
                                  "log": str(st / "service.out"), "status": rec}, indent=2))
                return 1
            time.sleep(1.0)
        print(json.dumps({"status": "still starting", "pid": proc.pid,
                          "log": str(st / "service.out")}))
        return 0
    return Service(opt).serve()


def cmd_shoot(args):
    import argparse
    ap = argparse.ArgumentParser(prog="goanna-render shoot")
    ap.add_argument("job")
    ap.add_argument("--no-start", action="store_true",
                    help="fail rather than start a service with the defaults")
    ap.add_argument("--timeout", type=float, default=7200.0)
    opt = ap.parse_args(args)
    job = json.loads(pathlib.Path(opt.job).read_text())
    if not service_record():
        if opt.no_start:
            print(json.dumps({"error": "no render service is running; goanna-render serve"}))
            return 1
        print("no render service running; starting one with the defaults", file=sys.stderr)
        if cmd_serve(["--game", job.get("game", "mineclonia")]) != 0:
            return 1
    st = state_dir()
    ident = "%s-%d-%s" % (time.strftime("%Y%m%d-%H%M%S"), os.getpid(),
                          safe_name(job.get("label", "job"))[:40])
    me = os.getpid()
    job["_submitter"] = {"pid": me, "start": gh.proc_start(me), "queued_at": time.time()}
    write_json(st / "queue" / (ident + ".json"), job)
    print("queued %s" % ident, file=sys.stderr)
    deadline = time.time() + opt.timeout
    said = None
    while time.time() < deadline:
        done = st / "done" / (ident + ".json")
        if done.exists():
            result = read_json(done)
            print(json.dumps(result, indent=2))
            return 0 if result and result.get("ok") else 1
        rec = service_record()
        if rec is None:
            print(json.dumps({"error": "the render service stopped before the job ran",
                              "id": ident}))
            return 1
        where = "running" if rec.get("current_job") == ident else \
            "queued, %d ahead" % sum(1 for q in rec.get("queue", []) if q < ident)
        line = "%s; service %s" % (where, rec.get("status"))
        if line != said:
            print(line, file=sys.stderr)
            said = line
        time.sleep(1.0)
    print(json.dumps({"error": "timed out waiting", "id": ident}))
    return 1


def cmd_status(_args):
    rec = service_record()
    print(json.dumps(rec or {"status": "not running"}, indent=2))
    return 0


def cmd_stop(_args):
    rec = service_record()
    if not rec:
        print(json.dumps({"status": "not running"}))
        return 0
    gh.signal_pid(int(rec["pid"]), signal.SIGTERM)
    deadline = time.time() + 120
    while time.time() < deadline and gh.alive(rec["pid"], rec["start"]):
        time.sleep(0.5)
    left = gh.alive(rec["pid"], rec["start"])
    print(json.dumps({"stopped": not left, "pid": rec["pid"]}))
    return 0 if not left else 1


USAGE = """usage:
  goanna-render serve [--game G] [--world-from WORLD] [--tier T] [--size WxH]
                      [--pack DIR] [--build CHECKOUT] [--idle-minutes N]
                      [--fake-gpu-user FILE] [--foreground]
  goanna-render shoot JOB.json [--no-start] [--timeout S]
  goanna-render status
  goanna-render stop
The job format is in docs/agents/agent-interfaces.md, under "The render service"."""


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    cmd, rest = argv[1], argv[2:]
    try:
        if cmd == "serve":
            return cmd_serve(rest)
        if cmd == "shoot":
            return cmd_shoot(rest)
        if cmd == "status":
            return cmd_status(rest)
        if cmd == "stop":
            return cmd_stop(rest)
    except (RenderError, gh.LaunchError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
