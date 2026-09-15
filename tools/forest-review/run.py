#!/usr/bin/env python3
"""Isolated cold TDL forest review; never visits or modifies the user's world."""
import argparse, json, os, shutil, socket, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--bake',type=Path,default=Path('/tmp/goanna-horizon-shore/world/terrain_diffusion'))
p.add_argument('--scratch',type=Path,default=Path('/tmp/goanna-forest-review'))
p.add_argument('--out',type=Path,default=ROOT/'build/forest-review')
p.add_argument('--game',default='mineclonia')
p.add_argument('--port',type=int,default=30869)
p.add_argument('--server-port',type=int,default=30572)
p.add_argument('--x',type=float,default=1600)
p.add_argument('--y',type=float,default=800)
p.add_argument('--z',type=float,default=1500)
p.add_argument('--headless',action='store_true')
p.add_argument('--keep',action='store_true')
p.add_argument('--project',type=Path,default=ROOT/'project',help='Project copy for isolated native-build comparisons')
a=p.parse_args(); scratch=a.scratch.resolve(); world=scratch/'world'; out=a.out.resolve()
world.mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
if not (world/'terrain_diffusion').exists():
    shutil.copytree(a.bake,world/'terrain_diffusion',copy_function=os.link)
for name,src in [('terrain_diffusion',ROOT/'project/vendor/terrain_diffusion'),('goanna_server_mod',ROOT/'goanna_server_mod')]:
    shutil.copytree(src,world/'worldmods'/name,dirs_exist_ok=True)
(world/'world.mt').write_text(f'gameid = {a.game}\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\n')
if not (world/'map_meta.txt').exists():
    (world/'map_meta.txt').write_text('mg_name = singlenode\nmcl_singlenode_mapgen = false\nseed = 1234\nchunksize = 5\n[end_of_params]\n')
config=scratch/'server.conf'
config.write_text(f'port = {a.server_port}\nname = forestreview\ncreative_mode = true\nenable_damage = false\nanticheat_flags = digging,interaction,nomovement\nserver_announce = false\nmax_block_send_distance = 6\nmax_block_generate_distance = 6\ntime_speed = 0\ndefault_privs = interact,shout,fly,fast,noclip,teleport,settime,server\nenable_mod_channels = true\ngoanna_far_rendering = true\ngoanna_far_rendering_distance = 1024\ngoanna_far_provider_distance = 2048\ngoanna_far_pregenerate = false\n')
server_log=(out/'server.log').open('w'); client_log=(out/'client.log').open('w')
server=subprocess.Popen(['flatpak','run',f'--filesystem={scratch}','--command=luanti','org.luanti.luanti','--server','--world',str(world),'--config',str(config),'--logfile',str(scratch/'server-debug.log')],stdout=server_log,stderr=subprocess.STDOUT)
env=os.environ.copy();env.update(GOANNA_HOST='127.0.0.1',GOANNA_PORT=str(a.server_port),GOANNA_NAME='forestreview',GOANNA_CONTROL=str(a.port),GOANNA_NO_PBR='1',GOANNA_VIEW_RANGE='6',GOANNA_FAR_DISTANCE='1024',GOANNA_TOD='0.4',XDG_DATA_HOME=str(scratch/'profile'),XDG_CONFIG_HOME=str(scratch/'config'))
time.sleep(2)
client=subprocess.Popen([str(ROOT.parent/'Godot_v4.5.1-stable_linux.x86_64'),'--path',str(a.project.resolve()),'--resolution','1280x720','--log-file',str(out/'godot.log')]+(['--headless'] if a.headless else []),env=env,stdout=client_log,stderr=subprocess.STDOUT)
def call(cmd,**args):
    with socket.create_connection(('127.0.0.1',a.port),timeout=3) as s:
        s.settimeout(60);s.sendall((json.dumps(dict(id=1,cmd=cmd,args=args))+'\n').encode());r=json.loads(s.makefile().readline())
    if not r.get('ok'): raise RuntimeError(r)
    return r['result']
try:
    end=time.monotonic()+180
    while time.monotonic()<end:
        if server.poll() is not None or client.poll() is not None: raise RuntimeError('Review process exited; inspect logs')
        try:
            if call('status').get('state')=='ready':break
        except OSError:pass
        time.sleep(1)
    else:raise RuntimeError('Review did not become ready')
    call('run',src='main.get_window().size=Vector2i(1280,720)\nmain.get_window().content_scale_size=Vector2i(1280,720)\nmain.get_window().content_scale_mode=Window.CONTENT_SCALE_MODE_VIEWPORT\nclient.set_show_body(false)\nreturn true')
    call('chat',text=f'/teleport {a.x},{a.y},{-a.z}')
    time.sleep(1)
    call('pose',x=a.x,y=a.y,z=a.z,pitch=-20,yaw=0)
    print(f'Ready on {a.port}; cold forest tiles loading',flush=True)
    start=time.monotonic()
    with (out/'load.jsonl').open('w') as f:
        for second in range(90):
            r=call('inspect',target='render');f.write(json.dumps(dict(t=time.monotonic()-start,render=r))+'\n');f.flush()
            if second%10==0:print({k:r.get(k) for k in ['surface_tiles','surface_reach','surface_forest_quads','surface_forest_columns','surface_first_ms']},flush=True)
            time.sleep(1)
    if not a.headless:call('shot',path=str(out/'forest.png'),settle=False,warm=5)
    if a.keep:
        while client.poll() is None:time.sleep(1)
finally:
    try:call('chat',text='/shutdown');call('quit')
    except (OSError,RuntimeError):pass
    client.terminate();server.terminate()
    for proc in (client,server):
        try:proc.wait(timeout=5)
        except subprocess.TimeoutExpired:proc.kill()
