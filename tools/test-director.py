#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""End to end test of the director on a real Mineclonia server.

It plays the model's part: it drives tools/goanna-director-mcp over MCP's
stdio JSON-RPC exactly as a model would, while a real Luanti server runs
goanna_server_mod with the director on, and headless Goanna clients
(software rendered, inside headless gamescope) are the players.

    tools/test-director.py [--keep] [--gpu]

It makes a throwaway world, goanna_director_test, under the Flatpak's
worlds directory (the only place the sandbox sees), and deletes it at the
end unless --keep is given. Ports: server 30920, control 30930 and 30931,
director HTTP 30960. It stops only the processes it started, by PID.

What it checks is listed as it goes; the exit status is the number of
checks that failed.
"""

import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

TOOLS = pathlib.Path(__file__).resolve().parent
REPO = TOOLS.parent
sys.path.insert(0, str(TOOLS))

import goanna_headless as gh  # noqa: E402

WORLDS = pathlib.Path.home() / ".var/app/org.luanti.luanti/.minetest/worlds"
WORLD = WORLDS / "goanna_director_test"
SERVER_PORT = 30920
CONTROL = {"alice": 30930, "bob": 30931}
HTTP_PORT = 30960
GAME = "mineclonia"

results = []


def check(cond, what, detail=None):
    results.append((bool(cond), what))
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or detail is None else
                                                  "\n     " + str(detail)[:600]), flush=True)
    return bool(cond)


def note(*parts):
    print("     " + " ".join(str(p) for p in parts), flush=True)


# --- the MCP service, spoken to as a model would -----------------------------

class Mcp:
    def __init__(self, world):
        self.proc = subprocess.Popen(
            [str(TOOLS / "goanna-director-mcp"), "--world", str(world)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(str(world) + ".mcp.log", "w"), text=True)
        self.next = 1
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "test-director", "version": "1"}})
        self.tools = [t["name"] for t in self.rpc("tools/list")["tools"]]

    def rpc(self, method, params=None):
        msg = {"jsonrpc": "2.0", "id": self.next, "method": method, "params": params or {}}
        self.next += 1
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        reply = json.loads(line)
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["result"]

    def call(self, _tool, **args):
        res = self.rpc("tools/call", {"name": _tool, "arguments": args})
        text = res["content"][0]["text"]
        if res.get("isError"):
            return {"tool_error": text}
        return json.loads(text)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:                                  # noqa: BLE001
            self.proc.kill()


# --- the control channel of a headless client --------------------------------

def control(port, cmd, args=None, timeout=60.0):
    request = json.dumps({"id": 1, "cmd": cmd, "args": args or {}}) + "\n"
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as sock:
        sock.settimeout(timeout)
        sock.sendall(request.encode())
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError("control channel closed")
            buf += chunk
    reply = json.loads(buf.split(b"\n", 1)[0], strict=False)
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error"))
    return reply.get("result")


ESC = re.compile(r"\x1b\([^)]*\)|\x1b[EF]")


def chat_lines(port):
    lines = control(port, "eval", {"expr": "ui.chat_lines"})
    if isinstance(lines, dict):
        lines = lines.get("value")
    out = []
    for line in lines or []:
        text = line.get("text", "") if isinstance(line, dict) else str(line)
        out.append(ESC.sub("", text))
    return out


def say(port, text):
    return control(port, "chat", {"text": text, "reply_ms": 800})


def wait_chat(port, needle, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in chat_lines(port):
            if needle in line:
                return line
        time.sleep(0.5)
    return None


# --- the server ----------------------------------------------------------------

def make_world():
    if WORLD.exists():
        shutil.rmtree(WORLD)
    (WORLD / "worldmods").mkdir(parents=True)
    shutil.copytree(REPO / "goanna_server_mod", WORLD / "worldmods" / "goanna_server_mod")
    (WORLD / "world.mt").write_text(
        "gameid = %s\nworld_name = goanna_director_test\nbackend = sqlite3\n"
        "player_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\n"
        "creative_mode = false\nenable_damage = true\n" % GAME)
    # Only the url: the mod has to create the token itself.
    (WORLD / "goanna_director.conf").write_text("url = http://127.0.0.1:%d\n" % HTTP_PORT)
    conf = WORLD / "director_test.conf"
    conf.write_text("\n".join([
        "name = alice",
        "default_privs = interact, shout, give, teleport",
        "enable_damage = true",
        "creative_mode = false",
        "mg_name = v7",
        "fixed_map_seed = 20261001",
        "mobs_spawn = false",
        "time_speed = 0",
        "world_start_time = 6000",
        "enable_mod_channels = true",
        "secure.http_mods = goanna_server_mod",
        "goanna_director = true",
        "goanna_director_join_grace = 0",
        "goanna_director_points_per_hour = 15",
        "goanna_director_relax = 10",
        "goanna_director_peak = 0.3",
        "goanna_director_relax_after_death = 20",
        "",
    ]))
    return conf


def start_server(conf):
    log = WORLD / "server.log"
    proc = subprocess.Popen(
        ["flatpak", "run", "--command=luanti", "org.luanti.luanti", "--server",
         "--world", str(WORLD), "--gameid", GAME, "--port", str(SERVER_PORT),
         "--config", str(conf), "--logfile", str(log)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return proc, log


def descendants(pid):
    out, frontier = [], [pid]
    while frontier:
        parent = frontier.pop()
        for d in pathlib.Path("/proc").iterdir():
            if not d.name.isdigit():
                continue
            st = gh.proc_stat(int(d.name))
            if st and st[1] == parent:
                out.append(int(d.name))
                frontier.append(int(d.name))
    return out


def stop_server(proc):
    # The Luanti process is a grandchild of the flatpak launcher we started.
    # SIGTERM to it is a clean shutdown; then the launcher exits by itself.
    for pid in descendants(proc.pid):
        try:
            comm = pathlib.Path("/proc/%d/comm" % pid).read_text().strip()
        except OSError:
            continue
        if comm.startswith("luanti"):
            os.kill(pid, signal.SIGTERM)
    try:
        proc.wait(timeout=40)
    except subprocess.TimeoutExpired:
        for pid in descendants(proc.pid):
            os.kill(pid, signal.SIGKILL)
        proc.kill()


def wait_log(log, needle, timeout=120.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if needle in log.read_text(errors="replace"):
                return True
        except OSError:
            pass
        time.sleep(0.5)
    return False


def events_of(mcp, etype, timeout=20.0, where=None):
    """Read events until one of etype (matching where) arrives."""
    deadline = time.time() + timeout
    seen = []
    while time.time() < deadline:
        batch = mcp.call("director_events", wait_s=min(5.0, max(0.5, deadline - time.time())))
        for ev in batch.get("events", []):
            seen.append(ev)
            if ev.get("type") == etype and (where is None or where(ev)):
                return ev, seen
    return None, seen


def drain(mcp):
    """Read whatever events are waiting, as a model does before it acts: an
    intent carries the last sequence it saw, and one based on an old view of
    a player who has since died or left is refused as stale."""
    batch = mcp.call("director_events", wait_s=0)
    return batch.get("events", [])


def main(argv):
    keep = "--keep" in argv
    software = "--gpu" not in argv
    for port in list(CONTROL.values()):
        if not gh.port_free(port):
            print("control port %d is in use" % port)
            return 1
    conf = make_world()
    server, log = start_server(conf)
    clients = []
    mcp = None
    try:
        check(wait_log(log, "[goanna director] on, session"), "the server mod starts the director")
        token = gh_conf(WORLD).get("token", "")
        check(re.fullmatch(r"[0-9a-f]{64}", token) is not None,
              "the mod created a 256 bit token in goanna_director.conf")

        # A player joins before any director is connected, and is told
        # nothing, because nothing is running.
        alice = gh.start_goanna(REPO, control_port=CONTROL["alice"], host="127.0.0.1",
                                port=SERVER_PORT, name="alice", software=software,
                                label="director test alice")
        clients.append(alice["id"])
        check(wait_log(log, "alice [", 60), "alice joins the server")
        time.sleep(3)
        check(not any("[director]" in l for l in chat_lines(CONTROL["alice"])),
              "with no director connected, no notice is given")

        # The director connects, as a model's MCP host would start it.
        mcp = Mcp(WORLD)
        check(set(mcp.tools) >= {"director_events", "director_player", "director_stage_encounter",
                                 "director_speak", "director_status", "director_stop",
                                 "director_undo"}, "the MCP service lists the director tools")
        check(not any(t in mcp.tools for t in ("goanna_run", "goanna_eval", "goanna_view",
                                               "goanna_command")),
              "and none of the developer tools")
        check(wait_log(log, "a director answered at", 30), "the server reached the MCP endpoint")
        time.sleep(1.5)
        status = mcp.call("director_status", detail=True)
        check(status.get("connected") and (status.get("capabilities") or {}).get("adapters", {})
              .get("mobs") == "mcl_mobs", "director_status: connected, mcl_mobs adapter",
              status)
        note("server says", json.dumps((status.get("capabilities") or {}).get("engine")),
             (status.get("capabilities") or {}).get("game"))
        ev, _ = events_of(mcp, "player_join", 30, lambda e: "player:alice" in e.get("who", []))
        check(ev is not None, "the model sees alice's join from before it connected", ev)
        notice = wait_chat(CONTROL["alice"], "[director]", 15)
        check(notice is not None and "optout" in notice and "exact positions" in notice,
              "alice is told when the director connects: what it sees, and how to opt out",
              notice or chat_lines(CONTROL["alice"]))

        summary = mcp.call("director_player", player="alice")
        check(summary.get("pos") and "gear" in summary and "encounter_ceiling" in summary,
              "director_player gives position, gear and a ceiling", summary)
        bare = summary.get("encounter_ceiling")
        note("bare handed:", json.dumps(summary.get("gear")), "ceiling", bare,
             "phase", json.dumps(summary.get("pacing")))

        say(CONTROL["alice"], "/giveme mcl_tools:sword_diamond")
        time.sleep(2)
        armed = mcp.call("director_player", player="alice")
        note("with a diamond sword:", json.dumps(armed.get("gear")), "ceiling",
             armed.get("encounter_ceiling"))
        check(armed.get("encounter_ceiling", 0) > (bare or 0),
              "a better weapon raises the encounter ceiling")
        ceiling = armed.get("encounter_ceiling")

        # An encounter sized to her gear.
        early = drain(mcp)
        note("events so far:", [(e["type"], e.get("data", {}).get("amount")
                                 or e.get("data", {}).get("cause")) for e in early][:12])
        # A model waits for the pacing layer. If alice has just died (a
        # fresh player sometimes takes damage at spawn while her blocks
        # arrive), the relax after a death has to run out first.
        deadline = time.time() + 90
        while time.time() < deadline:
            phase = mcp.call("director_player", player="alice").get("pacing", {}).get("phase")
            if phase == "build_up":
                break
            time.sleep(2)
        drain(mcp)
        enc = mcp.call("director_stage_encounter", near="alice", budget=100, when="now",
                       distance=[10, 18], leash_s=120,
                       reason="test: a first encounter for a lone player")
        if enc.get("reason") == "no_fauna":
            # Some biomes spawn no monsters (Mineclonia's PaleGarden is one).
            # A model then names the mobs it wants, as this does.
            note("no monster fauna in", enc.get("biome"), "so naming the mobs")
            enc = mcp.call("director_stage_encounter", near="alice", budget=100, when="now",
                           distance=[10, 18], leash_s=120,
                           mobs=["mobs_mc:zombie", "mobs_mc:skeleton", "mobs_mc:spider"],
                           reason="test: a first encounter for a lone player")
        check(enc.get("status") == "accepted" and enc.get("cost", 99) <= ceiling
              and enc.get("clamped_to_gear"),
              "an encounter asked for 100 is clamped to the gear ceiling and placed", enc)
        mobs = enc.get("mobs") or []
        note("staged", enc.get("id"), json.dumps([(m["mob"], m["pos"]) for m in mobs]),
             "cost", enc.get("cost"), "points left", enc.get("points_left"))
        ev, seen = events_of(mcp, "encounter_started", 10)
        check(ev is not None, "encounter_started arrives as an event")
        # Targeting: mcl_mobs itself picks alice as the target, and the mobs
        # close on her.
        first, closest, target, hurt = None, None, None, 0
        hurt0 = mcp.call("director_player", player="alice").get("last_10_min", {}).get("hurt", 0)
        deadline = time.time() + 30
        while time.time() < deadline:
            st = mcp.call("director_status", detail=True).get("server", {})
            live = [m for e in st.get("encounters") or [] for m in e.get("mobs") or []]
            dists = [m["distance"] for m in live if m.get("distance") is not None]
            if dists:
                first = first if first is not None else min(dists)
                closest = min(dists) if closest is None else min(closest, min(dists))
            target = target or next((m.get("target") for m in live if m.get("target")), None)
            hurt = mcp.call("director_player", player="alice").get("last_10_min", {}).get("hurt",
                                                                                     0) - hurt0
            if target == "alice" and (hurt > 0 or (first and closest < first - 3)):
                break
            time.sleep(2)
        note("mob target", target, "distance from", first, "to", closest,
             "alice hurt since staging", hurt)
        check(target == "alice", "mcl_mobs takes alice as the staged mobs' target")
        check(hurt > 0 or (first is not None and closest < first - 3),
              "the staged mobs close on her or hurt her", (first, closest, hurt))

        over = mcp.call("director_stage_encounter", near="alice", when="now",
                        mobs=["mobs_mc:zombie", "mobs_mc:skeleton", "mobs_mc:spider"],
                        reason="test: a second encounter that the hourly budget cannot pay")
        check(over.get("status") == "refused" and over.get("reason") == "budget",
              "a second encounter past the hourly points budget is refused", over)

        # Pacing: wait for the peak (the test lowers the threshold), queue a
        # small encounter for the next build up, end the first, and see the
        # queued one land once the cycle comes round.
        phase = None
        deadline = time.time() + 40
        while time.time() < deadline:
            phase = mcp.call("director_player", player="alice").get("pacing", {}).get("phase")
            if phase != "build_up":
                break
            time.sleep(1)
        check(phase in ("peak", "fade", "relax"), "harm and hostiles move alice out of build up",
              phase)
        now_refused = mcp.call("director_stage_encounter", near="alice", budget=4, when="now",
                               mobs=["mobs_mc:skeleton", "mobs_mc:spider"],
                               reason="test: now, outside a build up")
        check(now_refused.get("reason") == "pacing", "when=now outside a build up is refused",
              now_refused)
        queued = mcp.call("director_stage_encounter", near="alice", budget=4,
                          mobs=["mobs_mc:skeleton", "mobs_mc:spider"], leash_s=60,
                          reason="test: queued for the next build up")
        check(queued.get("status") == "queued", "next_build_up outside a build up is queued",
              queued)
        undone = mcp.call("director_undo", id=enc.get("id"), reason="test: undo")
        check(undone.get("status") == "undone", "undo of the encounter", undone)
        ev, _ = events_of(mcp, "encounter_ended", 10)
        check(ev is not None and ev["data"].get("outcome") in ("undone", "defeated", "player_died"),
              "encounter_ended reports the outcome", ev)
        st = mcp.call("director_status", detail=True)
        check(not st.get("server", {}).get("encounters"), "no live encounter is left", st)

        landed = None
        deadline = time.time() + 90
        while time.time() < deadline and not landed:
            batch = mcp.call("director_events", wait_s=5)
            for r in batch.get("late_results", []):
                if r.get("id") == queued.get("id"):
                    landed = r
        check(landed is not None and landed.get("status") == "completed",
              "the queued encounter lands at the next build up", landed)
        if landed and landed.get("status") == "completed":
            r = mcp.call("director_undo", id=queued.get("id"), reason="test: clear it")
            check(r.get("status") == "undone", "and is undone", r)

        # A character with a voice and a memory.
        cast = mcp.call("director_cast_npc", near="alice", name="Grimbold",
                        reason="test: a villager who talks")
        check(cast.get("status") == "accepted", "a named character is cast near alice", cast)
        impostor = mcp.call("director_cast_npc", near="alice", name="alice",
                            reason="test: a character may not take a player's name")
        check(impostor.get("status") == "refused" and impostor.get("reason") == "name_taken",
              "a character may not be named after a player", impostor)
        said = mcp.call("director_speak", **{"as": "Grimbold", "to": "alice",
                                              "text": "Well met, traveller. The road north is not safe."})
        check(said.get("status") == "completed" and said.get("delivered") == ["alice"],
              "speak as Grimbold to alice", said)
        line = wait_chat(CONTROL["alice"], "Grimbold (NPC): Well met", 10)
        check(line is not None, "alice reads it, attributed to the character", line)
        told = mcp.call("director_speak", **{"as": "narrator", "to": "all",
                                              "text": "A cold wind comes down from the hills."})
        check(told.get("status") == "completed", "speak as narrator to all", told)
        line = wait_chat(CONTROL["alice"], "[Narrator] A cold wind", 10)
        check(line is not None, "alice reads the narration, marked as narration", line)

        say(CONTROL["alice"], "Grimbold, where is the old tower?")
        ev, _ = events_of(mcp, "npc_addressed", 10)
        check(ev is not None and ev["data"].get("npc") == "Grimbold"
              and ev["data"]["memory"].get("spoken") == 1,
              "a line addressed to Grimbold reaches the model with his memory of alice", ev)
        rem = mcp.call("director_remember", npc="Grimbold", player="alice",
                       fact="asked about the old tower", disposition=20,
                       reason="test: remember the question")
        check(rem.get("status") == "completed", "remember a model written line", rem)
        too_long = mcp.call("director_remember", npc="Grimbold", player="alice",
                            fact="x" * 400, reason="test: over the cap")
        check(too_long.get("status") == "refused" and too_long.get("reason") == "too_long",
              "a memory line over the length cap is refused", too_long)
        say(CONTROL["alice"], "Grimbold, thank you")
        ev, _ = events_of(mcp, "npc_addressed", 10)
        facts = [f.get("text") for f in (ev or {}).get("data", {}).get("memory", {}).get("facts", [])]
        check(ev is not None and "asked about the old tower" in facts
              and ev["data"]["memory"].get("disposition") == 20,
              "the next address recalls the remembered line and disposition", ev)
        mem = mcp.call("director_memory", npc="Grimbold", player="alice")
        check(mem.get("memory", {}).get("addressed") == 2, "director_memory reads it back", mem)
        # A kill: alice strikes Grimbold down with her sword, through her own
        # client's dig action. The kill event names her, and the region
        # counts it.
        gpos = cast.get("pos")
        died = None
        if gpos:
            gx, gy, gz = gpos
            aim = ('var e = main._nearest_entity("villager")\n'
                   'if e.is_empty():\n\treturn null\n'
                   'main.fly_mode = false\n'
                   'main._aim_at(Vector3(e["position"]) + Vector3(0, 0.6, 0))\n'
                   'return (Vector3(e["position"]) - cam.position).length()')
            try:
                # The control channel takes Godot space, where z is negated.
                control(CONTROL["alice"], "tp", {"x": gx + 1.6, "y": gy, "z": -gz})
                where = ('var e = main._nearest_entity("villager")\n'
                         'return null if e.is_empty() else [e["position"].x, e["position"].y, '
                         'e["position"].z]')
                for _ in range(3):
                    at = (control(CONTROL["alice"], "run", {"src": where}) or {}).get("value")
                    reach = control(CONTROL["alice"], "run", {"src": aim}).get("value")
                    if at is None or (reach is not None and reach < 2.5):
                        break
                    control(CONTROL["alice"], "tp", {"x": at[0] + 1.2, "y": at[1], "z": at[2]})
                for _ in range(16):
                    reach = control(CONTROL["alice"], "run", {"src": aim}).get("value")
                    if reach is not None and reach > 2.5:
                        # Each blow knocks him back out of reach.
                        at = (control(CONTROL["alice"], "run", {"src": where}) or {}).get("value")
                        if at:
                            control(CONTROL["alice"], "tp",
                                    {"x": at[0] + 1.2, "y": at[1], "z": at[2]})
                            reach = control(CONTROL["alice"], "run", {"src": aim}).get("value")
                    # One punch per click: an object is struck on the press.
                    control(CONTROL["alice"], "key", {"key": "dig", "action": "tap"})
                    time.sleep(0.7)
                    died, _ = events_of(mcp, "entity_died", 0.5,
                                        lambda e: e["data"].get("npc") == "Grimbold")
                    if died:
                        break
                note("distance to the villager when striking:", reach)
            except RuntimeError as exc:
                note("could not strike:", exc)
            finally:
                try:
                    control(CONTROL["alice"], "key", {"key": "dig", "action": "release"})
                except RuntimeError:
                    pass
        if not died:
            died, _ = events_of(mcp, "entity_died", 8, lambda e: e["data"].get("npc") == "Grimbold")
        check(died is not None and died["data"].get("killer") == "alice"
              and "player:alice" in died.get("who", []),
              "a kill reaches the model as entity_died with the killer", died)
        if died:
            time.sleep(1.5)
            mem = mcp.call("director_memory", npc="Grimbold", player="alice")
            facts = [f.get("text") for f in mem.get("memory", {}).get("facts", [])]
            check("was killed by alice" in facts,
                  "the character's memory outlives it, with the kill as an event fact", mem)
            r = mcp.call("director_speak", **{"as": "Grimbold", "to": "alice", "text": "Ugh."})
            check(r.get("status") == "refused" and r.get("reason") == "unknown_speaker",
                  "a dead character no longer speaks", r)
            region = mcp.call("director_player", player="alice").get("region_summary") or {}
            note("region:", json.dumps(region)[:400])
            check(sum((region.get("kills") or {}).values()) >= 1, "the region counts the kill",
                  region)

        # Chat mode all, the default since 2026-10-01: every public line
        # reaches the model, and a direct message never does.
        say(CONTROL["alice"], "anyone seen the swamp witch lately")
        chatter, _ = events_of(mcp, "player_chat", 10,
                               lambda e: "swamp witch" in json.dumps(e))
        check(chatter is not None, "an ordinary public line reaches the model", chatter)
        say(CONTROL["alice"], "/msg alice secret plans for the tower")
        private, _ = events_of(mcp, "player_chat", 4,
                               lambda e: "secret plans" in json.dumps(e))
        check(private is None, "a direct message never reaches the model", private)

        # A second player, who opts out.
        bob = gh.start_goanna(REPO, control_port=CONTROL["bob"], host="127.0.0.1",
                              port=SERVER_PORT, name="bob", software=software,
                              label="director test bob")
        clients.append(bob["id"])
        ev, _ = events_of(mcp, "player_join", 90, lambda e: "player:bob" in e.get("who", []))
        check(ev is not None, "the model sees bob join")
        time.sleep(1)
        drain(mcp)
        check(wait_chat(CONTROL["bob"], "/director optout", 30) is not None,
              "bob is told how to opt out")
        say(CONTROL["bob"], "/director optout")
        check(wait_chat(CONTROL["bob"], "The director will leave you alone", 5),
              "bob opts out", chat_lines(CONTROL["bob"])[-4:])
        time.sleep(1.5)
        drain(mcp)
        bs = mcp.call("director_player", player="bob")
        check(bs.get("opted_out") and "pos" not in bs and "gear" not in bs,
              "an opted out player's summary says only that", bs)
        r = mcp.call("director_speak", **{"as": "narrator", "to": "bob", "text": "Psst."})
        check(r.get("status") == "refused" and r.get("reason") == "opted_out",
              "narration to an opted out player is refused", r)
        r = mcp.call("director_speak", **{"as": "narrator", "to": "all",
                                           "text": "The bell tolls once."})
        check(r.get("status") == "completed" and r.get("delivered") == ["alice"],
              "narration to all leaves bob out", r)
        time.sleep(1.5)
        check(not any("The bell tolls" in l for l in chat_lines(CONTROL["bob"])),
              "bob's client never receives it")
        r = mcp.call("director_stage_encounter", near="bob", when="now",
                     reason="test: an encounter for an opted out player")
        check(r.get("status") == "refused" and r.get("reason") == "opted_out",
              "an encounter near an opted out player is refused", r)
        r = mcp.call("director_remember", npc="Grimbold", player="bob", fact="met bob",
                     reason="test: memory of an opted out player")
        check(r.get("status") == "refused" and r.get("reason") == "opted_out",
              "nothing is remembered of an opted out player", r)
        gh.stop(bob["id"])
        clients.remove(bob["id"])
        time.sleep(3)
        batch = mcp.call("director_events", wait_s=2)
        check(not any("player:bob" in e.get("who", []) for e in batch.get("events", [])),
              "after opting out, nothing about bob is reported, not even his leaving",
              batch.get("events"))

        # The MCP service restarts: the server says hello again and the
        # stream carries on.
        mcp.close()
        time.sleep(2)
        mcp = Mcp(WORLD)
        deadline = time.time() + 40
        status = {}
        while time.time() < deadline:
            status = mcp.call("director_status", detail=True)
            if status.get("connected") and status.get("capabilities"):
                break
            time.sleep(1)
        check(status.get("connected") and status.get("capabilities"),
              "a restarted MCP service gets a fresh hello", status)
        r = mcp.call("director_player", player="alice")
        check(r.get("online") and r.get("pos"), "and can query again", r)

        # Stop, refuse, start.
        stopped = mcp.call("director_stop", reason="test: stop")
        check(stopped.get("status") == "completed", "director_stop", stopped)
        r = mcp.call("director_speak", **{"as": "narrator", "to": "alice", "text": "Hello?"})
        check(r.get("status") == "refused" and r.get("reason") == "stopped",
              "everything is refused while stopped", r)
        r = mcp.call("director_speak", **{"as": "Grimbold", "to": "alice", "text": "Hello?"})
        st = mcp.call("director_status", detail=True)
        check(not st.get("server", {}).get("npcs"), "stop removed the cast character", st)
        out = say(CONTROL["alice"], "/director start")
        note("alice:", out.get("server_said"))
        st = mcp.call("director_status", detail=True)
        check(st.get("server", {}).get("stopped") is False, "/director start by the operator", st)
        say(CONTROL["alice"], "/director")
        check(wait_chat(CONTROL["alice"], "is a language model acting as game master", 5),
              "/director describes itself", chat_lines(CONTROL["alice"])[-6:])
        say(CONTROL["alice"], "/director log")
        time.sleep(1.5)
        note("log:", chat_lines(CONTROL["alice"])[-8:])

        time.sleep(2)
        audit = list((WORLD / "goanna_director").glob("audit-*.jsonl"))
        lines = audit[0].read_text().splitlines() if audit else []
        types = {json.loads(l).get("type") for l in lines}
        check({"stage_encounter", "speak", "remember", "undo", "stop"} <= types,
              "the audit log has every intent (%d lines)" % len(lines), types)
        log_text = log.read_text(errors="replace")
        problems = [l for l in log_text.splitlines()
                    if "goanna director" in l and ("WARNING" in l or "ERROR" in l)]
        check(not problems, "no director warnings or errors in the server log", problems[:5])
        check("Support for dumping functions" not in log_text,
              "no function serialisation warnings from mcl_mobs staticdata")
    finally:
        for ident in clients:
            try:
                gh.stop(ident)
            except Exception as exc:                       # noqa: BLE001
                print("could not stop", ident, exc)
        stop_server(server)
        if mcp:
            mcp.close()
        if not keep:
            shutil.rmtree(WORLD, ignore_errors=True)
            try:
                os.remove(str(WORLD) + ".mcp.log")
            except OSError:
                pass
    failed = sum(1 for ok, _ in results if not ok)
    print("%d checks, %d failed" % (len(results), failed))
    return failed


def gh_conf(world):
    out = {}
    for line in (world / "goanna_director.conf").read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


if __name__ == "__main__":
    sys.exit(main(sys.argv))
