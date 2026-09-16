#!/usr/bin/env python3
"""Launch an isolated live dig review: the same dig, carve off and carve on.

    python3 tools/dig-review/run.py

Goanna already carries a dig harness: GOANNA_DIGTEST in project/main.gd points
the player at the ground, digs from t=4.0 to t=4.9, and saves a shot mid dig
plus four as the node breaks. This runs it twice against one world, once with
GOANNA_CARVE=0 so the dig is the crack overlay alone and once with carving on,
so the pair is the same dig on the same node and the only difference is the
thing being reviewed.

World and profiles stay in a scratch directory. Adapted from
tools/grass-review/run.py, which is the pattern for every live review here.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--out', type=Path, default=ROOT / 'build/dig-review')
ap.add_argument('--server-port', type=int, default=30571)
ap.add_argument('--scratch', type=Path, default=Path('/tmp/goanna-dig-review'))
ap.add_argument('--carve', default='0.16', help='carve depth per crack step')
ap.add_argument('--seconds', type=float, default=18.0)
ap.add_argument('--demo', type=int, default=8,
                help='world Y of the static carve demo row, 0 = off')
ap.add_argument('--digsecs', type=float, default=6.0,
                help='how long to hold the dig button')
args = ap.parse_args()

out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
scratch = args.scratch.resolve()
master = scratch / 'world_master'
world = scratch / 'world'
master.mkdir(parents=True, exist_ok=True)

shutil.copytree(ROOT / 'goanna_server_mod', master / 'worldmods/goanna_server_mod',
                dirs_exist_ok=True)
fixture = master / 'worldmods/dig_review'
fixture.mkdir(parents=True, exist_ok=True)
shutil.copyfile(ROOT / 'tools/dig-review/fixture.lua', fixture / 'init.lua')
(fixture / 'mod.conf').write_text('name = dig_review\ndepends = default\n')
(master / 'world.mt').write_text(
    'gameid = minetest\nbackend = sqlite3\nplayer_backend = sqlite3\n'
    'auth_backend = sqlite3\nload_mod_goanna_server_mod = true\n'
    'load_mod_dig_review = true\n')
config = scratch / 'server.conf'
# A real mapgen, not singlenode: the dig harness looks down at the ground in
# front of the player and needs something hand diggable to be there.
config.write_text(
    f'mg_name = flat\nmgflat_spflags = nolakes,nohills\n'
    # NOT creative: creative_mode makes every dig instant in Minetest Game, so
    # the node pops on the first frame and there are no intermediate states at
    # all. That, and not the carve, is why the first runs showed one bite and
    # then nothing: measured, a tree at prog=0.90 one tenth of a second in.
    f'creative_mode = false\nenable_damage = false\n'
    f'server_announce = false\nport = {args.server_port}\n'
    f'max_block_send_distance = 8\nmax_block_generate_distance = 8\n'
    f'time_speed = 0\nenable_mod_channels = true\nfixed_map_seed = digreview\n')


def run(label, carve):
    # A pristine copy of the generated world, so the two runs dig the same
    # untouched node rather than the second one deepening the first one's hole.
    if world.exists():
        shutil.rmtree(world)
    shutil.copytree(master, world)
    shots = out / label
    shots.mkdir(parents=True, exist_ok=True)
    server_log = (out / f'server-{label}.log').open('w')
    client_log = (out / f'client-{label}.log').open('w')
    server = subprocess.Popen(
        ['flatpak', 'run', '--die-with-parent', f'--filesystem={scratch}',
         '--command=luanti',
         'org.luanti.luanti', '--server', '--world', str(world),
         '--gameid', 'minetest', '--config', str(config),
         '--logfile', str(scratch / f'luanti-{label}.log')],
        stdout=server_log, stderr=subprocess.STDOUT)
    env = os.environ.copy()
    env.update(GOANNA_HOST='127.0.0.1', GOANNA_PORT=str(args.server_port),
               GOANNA_NAME=f'digreview{label}', GOANNA_NO_PBR='1',
               GOANNA_VIEW_RANGE='12', GOANNA_TOD='0.38',
               GOANNA_DIGTEST='1', GOANNA_SHOT=str(shots), GOANNA_BODY='0', GOANNA_DIGSECS=str(args.digsecs),
               GOANNA_CARVE_DEMO=str(args.demo), GOANNA_CARVE_DEMO_Z='3',
               GOANNA_CARVE=str(carve),
               XDG_DATA_HOME=str(scratch / f'profile-{label}'),
               XDG_CONFIG_HOME=str(scratch / f'config-{label}'))
    time.sleep(6)
    client = subprocess.Popen(
        [str(ROOT.parent / 'Godot_v4.5.1-stable_linux.x86_64'),
         '--path', str(ROOT / 'project'), '--resolution', '1280x720',
         '--position', '40,40', '--log-file', str(out / f'godot-{label}.log')],
        env=env, stdout=client_log, stderr=subprocess.STDOUT)
    try:
        client.wait(timeout=args.seconds)
    except subprocess.TimeoutExpired:
        pass
    for proc in (client, server):
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    server_log.close()
    client_log.close()
    # The server has to actually let go of the player before the next run
    # connects, or the second client is refused with "that player is already
    # connected" and never reaches the dig. A distinct name per run makes that
    # impossible rather than unlikely; the pause is belt and braces on the port.
    time.sleep(3)
    got = sorted(p.name for p in shots.glob('*.png'))
    print(f'  {label:<5} carve={carve}  shots: {got or "NONE"}')
    return got


def warm():
    """Generate and settle the world once, so neither measured run pays for it.

    The harness digs on a wall clock: main.gd fires at t = 4.0 regardless of
    whether the client has connected. The first run of the first attempt was
    still connecting at t = 5 and photographed an empty sky. Generating the
    spawn area up front is what makes the two runs comparable.
    """
    log = (out / 'server-warm.log').open('w')
    proc = subprocess.Popen(
        ['flatpak', 'run', '--die-with-parent', f'--filesystem={scratch}',
         '--command=luanti',
         'org.luanti.luanti', '--server', '--world', str(master),
         '--gameid', 'minetest', '--config', str(config),
         '--logfile', str(scratch / 'luanti-warm.log')],
        stdout=log, stderr=subprocess.STDOUT)
    time.sleep(12)
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()
    print('  world generated')


print('dig review, same world, carve off then on')
warm()
run('off', '0')
run('on', args.carve)
print(f'\nshots under {out}')
