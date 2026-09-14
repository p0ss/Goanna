#!/usr/bin/env python3
"""Launch an isolated live grass review. World and profiles stay in /tmp."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, default=ROOT/'build/grass-review')
parser.add_argument('--keep', action='store_true')
parser.add_argument('--grass', choices=['on','off','saved'], default='on',
    help='Initial grass state; saved omits the environment override')
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
scratch = Path('/tmp/goanna-grass-review')
world = scratch/'world'
mod = world/'worldmods/grass_review'
mod.mkdir(parents=True, exist_ok=True)
shutil.copyfile(ROOT/'tools/grass-review/fixture.lua', mod/'init.lua')
(mod/'mod.conf').write_text('name = grass_review\ndepends = default\n')
animalia = Path.home()/'.var/app/org.luanti.luanti/.minetest/games/asuna/mods/animalia'
for source in ['models/animalia_sheep.b3d','textures/sheep/animalia_sheep.png','textures/sheep/animalia_sheep_wool.png']:
    path=animalia/source
    if path.exists():
        target=mod/('models' if path.suffix=='.b3d' else 'textures')/path.name
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(path,target)

shutil.copytree(ROOT/'goanna_server_mod', world/'worldmods/goanna_server_mod', dirs_exist_ok=True)
(world/'world.mt').write_text('gameid = minetest\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nload_mod_grass_review = true\nload_mod_goanna_server_mod = true\n')
config = scratch/'server.conf'
config.write_text('mg_name = singlenode\ncreative_mode = true\nenable_damage = false\nserver_announce = false\nport = 30567\nmax_block_send_distance = 20\nmax_block_generate_distance = 20\nmax_forceloaded_blocks = 0\ntime_speed = 0\nenable_mod_channels = true\ngoanna_far_rendering = true\ngoanna_far_rendering_distance = 1024\n')
server_log = (out/'server.log').open('w')
client_log = (out/'client.log').open('w')
server = subprocess.Popen(['flatpak','run',f'--filesystem={scratch}', '--command=luanti',
    'org.luanti.luanti','--server','--world',str(world),'--gameid','minetest',
    '--config',str(config),'--logfile',str(scratch/'luanti.log')], stdout=server_log, stderr=subprocess.STDOUT)
env = os.environ.copy()
env.update(GOANNA_HOST='127.0.0.1',GOANNA_PORT='30567',
    GOANNA_NAME='grassreview',GOANNA_CONTROL='30867',GOANNA_NO_PBR='1',
    GOANNA_VIEW_RANGE='20',GOANNA_TOD='0.38',
    XDG_DATA_HOME=str(scratch/'profile'),XDG_CONFIG_HOME=str(scratch/'config'))
if args.grass == 'saved':
    env.pop('GOANNA_GRASS',None)
else:
    env['GOANNA_GRASS']='1' if args.grass=='on' else '0'
time.sleep(2)
client = subprocess.Popen([str(ROOT.parent/'Godot_v4.5.1-stable_linux.x86_64'),
    '--path',str(ROOT/'project'),'--resolution','1280x720','--position','40,40',
    '--log-file',str(out/'godot.log')], env=env,stdout=client_log,stderr=subprocess.STDOUT)

def call(cmd, **params):
    with socket.create_connection(('127.0.0.1',30867), timeout=5) as s:
        s.settimeout(90)
        s.sendall((json.dumps(dict(id=1,cmd=cmd,args=params))+'\n').encode())
        reply=json.loads(s.makefile().readline())
    if not reply.get('ok'): raise RuntimeError(reply)
    return reply['result']

try:
    deadline=time.monotonic()+120
    while time.monotonic()<deadline:
        if server.poll() is not None or client.poll() is not None:
            raise RuntimeError('Review process exited; see logs')
        try:
            if call('status').get('state')=='ready': break
        except OSError: pass
        time.sleep(1)
    else: raise RuntimeError('Client did not become ready')
    call('label',text='Procedural grass review')
    call('set',key='far_distance',value=512)
    call('pose',x=6,y=82,z=0,pitch=-8,yaw=0)
    time.sleep(12)
    call('wait',settle=True)
    call('shot',path=str(out/'first.png'),settle=False,warm=20)
    (out/'first.json').write_text(json.dumps(call('inspect',target='render'),indent=2))
    print(f'Ready on 30867. Capture: {out / "first.png"}',flush=True)
    if args.keep:
        while client.poll() is None: time.sleep(1)
finally:
    client.terminate()
    server.terminate()
    for proc in (client,server):
        try: proc.wait(timeout=10)
        except subprocess.TimeoutExpired: proc.kill()
