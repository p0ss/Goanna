#!/usr/bin/env python3
"""Live surface regression: fixed hits, cancelled cuts and chunk corner reveals.
Run after run.py has generated /tmp/goanna-dig-local/world_master.
Uses its own world/profile and never touches a player's world.
"""
import argparse, json, os, shutil, socket, subprocess, time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gif",action="store_true",help="record centre and corner digs")
parser.add_argument("--rhythm",action="store_true",help="capture contact timing and the Mineclonia arm")
options=parser.parse_args()
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
SCRATCH=Path('/tmp/goanna-dig-boundary')
OUT=ROOT/('build/dig-rhythm' if options.rhythm else 'build/dig-gif' if options.gif else 'build/dig-boundary')
OUT.mkdir(parents=True,exist_ok=True)
world=SCRATCH/'world'
if world.exists(): shutil.rmtree(world)
shutil.copytree('/tmp/goanna-dig-local/world_master',world)
shutil.copyfile(ROOT/'tools/dig-review/boundary.lua',world/'worldmods/dig_review/init.lua')
game = 'mineclonia' if options.rhythm else 'minetest'
if options.rhythm:
    fixture=world/'worldmods/dig_review/init.lua'
    fixture.write_text(fixture.read_text().replace('default:stone','mcl_core:stone').replace('default:brick','mcl_core:brick_block') + '\nminetest.override_item("mcl_core:stone", {groups={cracky=3}})\n')
    with fixture.open('a') as f:
        f.write('\nminetest.register_tool("dig_review:pick", {description="Timing pick", inventory_image="default_tool_steelpick.png", tool_capabilities={full_punch_interval=1, groupcaps={cracky={times={[1]=4,[2]=4,[3]=4},uses=0,maxlevel=3}}}})\nminetest.register_on_joinplayer(function(p) p:get_inventory():set_stack("main",1,"dig_review:pick") end)\n')
    (fixture.parent/'mod.conf').write_text('name = dig_review\ndepends = mcl_core\n')
    mt=world/'world.mt'
    mt.write_text(mt.read_text().replace('gameid = minetest','gameid = mineclonia'))
config=SCRATCH/'server.conf'
config.write_text('mg_name = flat\ncreative_mode = false\nenable_damage = false\nserver_announce = false\nport = 30579\ntime_speed = 0\nenable_mod_channels = true\nmax_block_send_distance = 5\n')
logs=[]
def launch(args,path,env=None):
    log=open(OUT/path,'w');logs.append(log)
    return subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,env=env)
def cmd(name,**args):
    with socket.create_connection(('127.0.0.1',30879),timeout=30) as s:
        s.settimeout(120)
        s.sendall((json.dumps({'id':1,'cmd':name,'args':args})+'\n').encode())
        data=b''
        while b'\n' not in data: data+=s.recv(1048576)
    result=json.loads(data.split(b'\n')[0])
    if not result.get('ok',True): raise RuntimeError(result)
    return result
server=launch(['flatpak','run','--die-with-parent',f'--filesystem={SCRATCH}','--command=luanti','org.luanti.luanti','--server','--world',str(world),'--gameid',game,'--config',str(config)],'server.log')
client=None
try:
    time.sleep(4)
    env=os.environ.copy()
    env.update(GOANNA_HOST='127.0.0.1',GOANNA_PORT='30579',GOANNA_NAME='digboundary',GOANNA_CONTROL='30879',GOANNA_VIEW_RANGE='5',GOANNA_TOD='0.5',GOANNA_DEBUG_ARM='1' if options.rhythm else '',GOANNA_BODY='1' if options.rhythm else '0',GOANNA_CARVE='0.12',GOANNA_NO_PBR='1',GOANNA_SDFGI='0',GOANNA_AMBIENT='2',GOANNA_BEVEL='0',XDG_DATA_HOME=str(SCRATCH/'profile'),XDG_CONFIG_HOME=str(SCRATCH/'config'))
    client=launch([str(ROOT.parent/'Godot_v4.5.1-stable_linux.x86_64'),'--path',str(ROOT/'project'),'--resolution','1280x720','--position','40,40'],'client.log',env)
    for _ in range(90):
        try:
            result=cmd('status')
            if 'ready' in json.dumps(result): break
        except (OSError,ValueError): pass
        time.sleep(1)
    else: raise RuntimeError('client did not become ready')
    time.sleep(8)
    trace=[]
    if options.rhythm:
        cmd('pose',x=7.65,y=10.0,z=-5.9,fly=True)
        cmd('look',x=7.0,y=8.5,z=-7.0)
        time.sleep(2)
        source=(ROOT/'tools/dig-review/rhythm.gd').read_text().replace('@OUTPUT@',json.dumps(str(OUT)))
        result=cmd('run',src=source)['result']['value']
        (OUT/'states.json').write_text(json.dumps(result,indent=2))
        impacts=[r for r in result if r.get('dig_impact')]
        assert len(impacts)==8,impacts
        assert [r['chips'] for r in impacts]==[5]*7+[16],impacts
        assert all(r['swing']==1 and r['sounds']>=1 for r in impacts),impacts
        assert all(abs(r['carve_volume']-(1-r['impact_progress']))<.015 for r in impacts),impacts
        assert all(r['chips']==0 for r in result if not r.get('dig_impact')),result
        windups=[r['arm_pose'] for r in result if r['swing']==0 and 30<r['frame']<145]
        assert len(windups)>10,windups
        assert all(max(p[i] for p in windups)-min(p[i] for p in windups)<.001 for i in range(9)),windups
        assert any(r.get('node_name')=='air' for r in result),result[-1]
        print('Eight contacts and sound/chip bursts, each at the end of a stroke',flush=True)
        cmd('quit')
    if options.gif:
        for label,base,offset in [('centre',7,0.0),('corner',15,0.34)]:
            cmd('pose',x=base+.65,y=10.0,z=-base+1.1,fly=True)
            cmd('look',x=base+offset,y=8.5,z=-base-offset)
            time.sleep(1)
            frames=OUT/label
            frames.mkdir(exist_ok=True)
            cmd('shot',path=str(frames/'00.png'))
            src='var trace = []\n'
            src+='for stage in range(1,21):\n\tvar result = {}\n'
            src+='\tfor i in range(600):\n\t\tclient.step_player(0.0001, {}, main.pitch, main.yaw)\n\t\tclient.set_player_pose(cam.position, main.pitch, main.yaw)\n\t\tresult = client.step_interact(0.0125, true, false, false, false)\n\t\tawait main.get_tree().process_frame\n\t\tif (stage < 20 and result.get("progress", 0.0) >= float(stage)/20.0) or result.get("node_name", "") == "air":\n\t\t\tbreak\n'
            src+='\ttrace.append(result)\n\tif stage == 20:\n\t\tawait main.get_tree().create_timer(0.8).timeout\n\tawait main.get_tree().process_frame\n\tawait RenderingServer.frame_post_draw\n'
            src+=f'\tmain.get_viewport().get_texture().get_image().save_png({json.dumps(str(frames))}.path_join("%02d.png" % stage))\n'
            src+='client.step_interact(0.0, false, false, false, false)\nreturn trace'
            result=cmd('run',src=src)
            states=result['result']['value']
            assert len(states)==20 and states[0].get('node_name')=='default:stone',states
            assert states[-1].get('node_name')=='air',states[-1]
            (frames/'states.json').write_text(json.dumps(states,indent=2))
        cmd('quit')
    for label,base in ([] if options.gif or options.rhythm else [('interior',7),('boundary',15)]):
        # Aim down onto the far corner of the target. In Godot Z is negated.
        cmd('pose',x=base+.8,y=10.4,z=-base+1.6,fly=True)
        cmd('look',x=base+.34,y=8.5,z=-base-.34)
        time.sleep(2)
        cmd('shot',path=str(OUT/f'{label}-before.png'))
        for stage in range(1,5):
            result=cmd('run',src=f'var result = {{}}\nfor i in range(400):\n\tclient.step_player(0.0001, {{}}, main.pitch, main.yaw)\n\tclient.set_player_pose(cam.position, main.pitch, main.yaw)\n\tresult = client.step_interact(0.025, true, false, false, false)\n\tawait main.get_tree().process_frame\n\tif result.get("progress",0.0) >= {stage*.2}:\n\t\tbreak\nreturn result')
            trace.append({'case':label,'stage':stage,'state':result})
            (OUT/'states.json').write_text(json.dumps(trace,indent=2))
            state=result['result']['value']
            assert state.get('type')=='node' and state.get('crack_level',-1)>=0, state
            assert state.get('node_name')=='default:stone', state
            time.sleep(.5)
            cmd('shot',path=str(OUT/f'{label}-{stage}.png'))
        cmd('run',src='return client.step_interact(0.0, false, false, false, false)')
        time.sleep(1)
        cmd('shot',path=str(OUT/f'{label}-cancel.png'))
        result=cmd('run',src='var result = {}\nfor i in range(500):\n\tclient.step_player(0.0001, {}, main.pitch, main.yaw)\n\tclient.set_player_pose(cam.position, main.pitch, main.yaw)\n\tresult = client.step_interact(0.025, true, false, false, false)\n\tawait main.get_tree().process_frame\n\tif result.get("node_name", "") == "air":\n\t\tbreak\nreturn result')
        assert result['result']['value'].get('node_name')=='air',result
        trace.append({'case':label,'stage':'complete','state':result})
        cmd('run',src='return client.step_interact(0.0, false, false, false, false)')
        time.sleep(1)
        cmd('shot',path=str(OUT/f'{label}-complete.png'))
    if not options.rhythm: (OUT/'states.json').write_text(json.dumps(trace,indent=2))
    if not options.gif and not options.rhythm: cmd('quit')
finally:
    for proc in (client,server):
        if proc is None: continue
        proc.terminate()
        try: proc.wait(timeout=8)
        except subprocess.TimeoutExpired: proc.kill();proc.wait()
    for log in logs: log.close()
print(OUT)
