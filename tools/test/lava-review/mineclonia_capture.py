#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Capture the real Mineclonia falling-liquid material at four flow phases."""
import argparse
import json
import socket
from pathlib import Path

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('stage')
args = ap.parse_args()
out = Path('/tmp/goanna-lava-mineclonia/review')/args.stage
out.mkdir(parents=True, exist_ok=True)

def call(cmd, **args):
    with socket.create_connection(('127.0.0.1',30882),timeout=15) as sock:
        sock.settimeout(120)
        sock.sendall((json.dumps({'id':1,'cmd':cmd,'args':args})+'\n').encode())
        result = json.loads(sock.makefile('r').readline())
    if not result.get('ok'):
        raise RuntimeError(result)
    return result['result']

call('run',src='main.headlight_auto=false; main.headlight.light_energy=0; client.set_show_body(false); client.set_light_flicker(false); ResourceLoader.load("res://shaders/lava.gdshader","Shader",ResourceLoader.CACHE_MODE_REPLACE); return true')
call('pose',x=25,y=3,z=-7,pitch=0,yaw=145)
call('look',x=20,y=3,z=0)
call('time',tod=0)
call('wait',frames=180)
call('run',src='main.set_process(false); return true')
try:
    for t in [0,3,6,9]:
        state = call('run',src=f'''var result = []
for node in main.find_children("*","MeshInstance3D",true,false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if not mat is ShaderMaterial or mat.shader.resource_path != "res://shaders/lava.gdshader":
			continue
		mat.set_shader_parameter("preview_time",{t}.0)
		var tex = mat.get_shader_parameter("albedo_tex")
		if result.is_empty():
			var img = tex.get_image()
			if img.is_compressed():
				img.decompress()
			img.save_png({json.dumps(str(out/'resolved-texture.png'))})
		result.append({{"size":[tex.get_width(),tex.get_height()],"energy":mat.get_shader_parameter("emission_energy"),"native":mat.get_shader_parameter("surface_geometry"),"range":str(mat.get_shader_parameter("crust_range")),"strength":mat.get_shader_parameter("crust_strength")}})
return result''')['value']
        call('shot',path=str(out/f'phase-{t}.png'),settle=False,warm=24)
        (out/'materials.json').write_text(json.dumps(state,indent=2))
finally:
    call('run',src='''for node in main.find_children("*","MeshInstance3D",true,false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if mat is ShaderMaterial and mat.shader.resource_path == "res://shaders/lava.gdshader":
			mat.set_shader_parameter("preview_time",-1.0)
main.set_process(true)
return true''')
print(out)
