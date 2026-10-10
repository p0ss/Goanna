#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Compare a real torch and a spreading lava source in identical sealed caves."""
import argparse
import json
import socket
from pathlib import Path
from PIL import Image
import numpy as np

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('stage')
parser.add_argument('--port',type=int,default=30880)
parser.add_argument('--output',type=Path,default=Path('/tmp/goanna-lava-cave/review'))
parser.add_argument('--gain',type=float,default=1.0)
parser.add_argument('--lift',type=float,default=0.0)
parser.add_argument('--glow-gain',type=float,default=1.0)
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)

def call(cmd,**params):
    with socket.create_connection(('127.0.0.1',args.port),timeout=15) as sock:
        sock.settimeout(120)
        sock.sendall((json.dumps({'id':1,'cmd':cmd,'args':params})+'\n').encode())
        reply=json.loads(sock.makefile('r').readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']

call('run',src='main.headlight_auto=false; main.headlight.light_energy=0.0; client.set_light_flicker(false); client.set_show_body(false); return true')
call('time',tod=0.0)
results={}
for room,cx in [('lava',20),('torch',-20)]:
    call('run',src='main.set_process(true); return true')
    call('pose',x=cx,y=7,z=-13,pitch=-45,yaw=180)
    call('look',x=cx,y=0.5,z=-7)
    call('wait',frames=180)
    call('run',src='main.set_process(false); return true')
    try:
        state=call('run',src=f'''var result = {{"lights":[],"probes":[],"edge_zero":0,"edge_full":0}}
for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.get_parent() == client and lamp.visible:
		lamp.set_meta("cave_energy", lamp.light_energy)
		lamp.set_meta("cave_position", lamp.position)
		if lamp.position.x > 0.0:
			lamp.light_energy *= {args.gain}
			lamp.position.y += {args.lift}
		result.lights.append([lamp.position.x,lamp.position.y,lamp.position.z,lamp.light_energy])
for node in main.find_children("*", "MeshInstance3D", true, false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if mat is ShaderMaterial and mat.shader.resource_path == "res://shaders/lava.gdshader":
			mat.set_shader_parameter("preview_time",2.0)
			if not mat.has_meta("cave_emission"):
				mat.set_meta("cave_emission", mat.get_shader_parameter("emission_energy"))
			mat.set_shader_parameter("emission_energy",mat.get_meta("cave_emission") * {args.glow_gain})
			for colour in node.mesh.surface_get_arrays(i)[Mesh.ARRAY_COLOR]:
				if colour.a < 0.01:
					result.edge_zero += 1
				if colour.a > 0.99:
					result.edge_full += 1
for r in range(1,13):
	var p = Vector3({cx}+1.0,0.51,-r)
	var screen = cam.unproject_position(p)
	result.probes.append({{"r":r,"pixel":[screen.x,screen.y],"above":client.node_name_at(p+Vector3(0,0.5,0))}})
return result''')['value']
        path=args.output/f'{room}-{args.stage}.png'
        call('shot',path=str(path.resolve()),settle=False,warm=32)
        img=np.asarray(Image.open(path).convert('RGB'),dtype=float)/255
        for probe in state['probes']:
            x,y=map(round,probe['pixel'])
            if 5<=x<img.shape[1]-5 and 5<=y<img.shape[0]-5:
                rgb=img[y-4:y+5,x-4:x+5].mean((0,1))
                probe['rgb']=rgb.tolist()
                probe['luma']=float(rgb@np.array([0.2126,0.7152,0.0722]))
        results[room]=state
        print(room,json.dumps(state),flush=True)
    finally:
        call('run',src='''for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.has_meta("cave_energy"):
		lamp.light_energy = lamp.get_meta("cave_energy")
		lamp.position = lamp.get_meta("cave_position")
		lamp.remove_meta("cave_energy")
		lamp.remove_meta("cave_position")
for node in main.find_children("*", "MeshInstance3D", true, false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if mat is ShaderMaterial and mat.shader.resource_path == "res://shaders/lava.gdshader":
			mat.set_shader_parameter("preview_time",-1.0)
			if mat.has_meta("cave_emission"):
				mat.set_shader_parameter("emission_energy",mat.get_meta("cave_emission"))
				mat.remove_meta("cave_emission")
main.set_process(true)
return true''')
(args.output/f'{args.stage}.json').write_text(json.dumps(results,indent=2))
