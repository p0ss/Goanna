#!/usr/bin/env python3
"""Flood/drain an isolated grass-review pool; inspect roots and capture angles."""
import argparse
import json
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lod-only', action='store_true')
parser.add_argument('--no-shots', action='store_true')
parser.add_argument('--port', type=int, default=30868)
parser.add_argument('--out', type=Path, default=Path('build/grass-review/water-fixed'))
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)

def call(cmd, **params):
    if cmd == 'shot' and args.no_shots:
        return {}
    with socket.create_connection(('127.0.0.1', args.port), timeout=5) as sock:
        sock.settimeout(90)
        sock.sendall((json.dumps(dict(id=1, cmd=cmd, args=params))+'\n').encode())
        reply = json.loads(sock.makefile().readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']

def run(src):
    return call('run', src=src)['value']

# Inspect the actual grass surface's custom vertex attributes, not its cache.
ROOTS = '''var result={"pool_area":0.0,"bank_area":0.0,"surfaces":0,"lod_pool_area":0.0}
for n in client.get_children():
	if not n is MeshInstance3D or not n.visible or not n.mesh: continue
	for s in n.mesh.get_surface_count():
		var m=n.mesh.surface_get_material(s)
		if not m or not m.has_meta("goanna_grass_volume"): continue
		result.surfaces+=1
		var a=n.mesh.surface_get_arrays(s)
		var bounds=a[Mesh.ARRAY_CUSTOM0]
		var roots=a[Mesh.ARRAY_CUSTOM1]
		for i in range(0,roots.size(),32):
			var y=roots[i]+n.position.y
			var x0=bounds[i]+n.position.x
			var z0=bounds[i+1]+n.position.z
			var x1=bounds[i+2]+n.position.x
			var z1=bounds[i+3]+n.position.z
			if y>126.4 and y<128.0:
				var area=maxf(0.0,minf(x1,19.5)-maxf(x0,12.5))*maxf(0.0,minf(z1,5.5)-maxf(z0,-1.5))
				result.pool_area+=area
				if n.mesh.get_meta("goanna_grass_lod",false): result.lod_pool_area+=area
			if abs(y-128.5)<0.01:
				result.bank_area+=maxf(0.0,minf(x1,22.5)-maxf(x0,9.5))*maxf(0.0,minf(z1,8.5)-maxf(z0,-4.5))
return result'''
run('main.get_window().size=Vector2i(1280,720)\nmain.get_window().content_scale_size=Vector2i(1280,720)\nmain.get_window().content_scale_mode=Window.CONTENT_SCALE_MODE_VIEWPORT\nclient.set_show_body(false)\nclient.set_lod_distance(20)\nreturn true')
if not args.lod_only:
    call('pose', x=16, y=135, z=13, pitch=-38, yaw=0)
results = {}
for state in (() if args.lod_only else ('dry', 'wet', 'toggle', 'drained')):
    if state == 'toggle':
        run('main.set_procedural_grass(false)\nmain.set_procedural_grass(true)\nreturn true')
    else:
        call('chat', text='/grass_water'+(' dry' if state in ('dry','drained') else ''))
    time.sleep(4)
    call('wait', frames=60)
    result = run(ROOTS)
    results[state] = result
    print(state, result, flush=True)
    call('shot', path=str(out/f'pool-{state}.png'), settle=False, warm=10)
    (out/'water-results.json').write_text(json.dumps(results, indent=2))
    assert result['bank_area'] >= 119.9, ('Missing dry bank', state, result)
    expected = 49.0 if state in ('dry', 'drained') else 0.0
    assert abs(result['pool_area']-expected)<0.1, ('Wrong pool grass coverage', state, result)
call('chat', text='/grass_water')
time.sleep(4)
for label, pose in {
    'side':dict(x=27,y=132,z=2,pitch=-22,yaw=90),
    'underwater':dict(x=16,y=127.5,z=2,pitch=0,yaw=0),
}.items() if not args.lod_only else []:
    call('pose', **pose)
    call('wait', frames=60)
    call('shot', path=str(out/f'pool-{label}.png'), settle=False, warm=10)
run('client.set_lod_distance(2)\nreturn true')
call('pose', x=16, y=140, z=55, pitch=-15, yaw=0)
for state in ('lod-wet', 'lod-dry', 'lod-reflooded'):
    call('chat', text='/grass_water'+(' dry' if state == 'lod-dry' else ''))
    time.sleep(6)
    call('wait', frames=90)
    expected = 49.0 if state == 'lod-dry' else 0.0
    # LOD regions publish independently after node edits. Wait for both sides
    # of the block boundary to finish, rather than sampling one stale region.
    deadline = time.monotonic()+90
    while True:
        result = run('client.poll_blocks(64)\nclient.update_lod(cam.position,64)\n'+ROOTS)
        if abs(result['pool_area']-expected)<0.1 and result['bank_area']>=119.9 and (state!='lod-dry' or abs(result['lod_pool_area']-49.0)<0.1):
            break
        if time.monotonic()>=deadline:
            break
        time.sleep(0.5)
    results[state] = result
    print(state, result, flush=True)
    (out/'water-results.json').write_text(json.dumps(results, indent=2))
    assert abs(result['pool_area']-expected)<0.1, ('Wrong LOD pool coverage', state, result)
    if state == 'lod-dry':
        assert abs(result['lod_pool_area']-49.0)<0.1, ('Pool did not enter cached LOD', result)
    call('shot', path=str(out/f'pool-{state}.png'), settle=False, warm=10)
run('client.set_lod_distance(20)\nreturn true')
print('Grass water: '+('cached LOD' if args.lod_only else 'flood, drain, toggle, dry bank and cached LOD')+' PASS', flush=True)
