#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Capture continuity, relief and bank lighting in an isolated lava fixture."""
import argparse
import json
import socket
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=30879)
parser.add_argument('--output', type=Path, default=Path('/tmp/goanna-lava-world/review'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)

def call(cmd, **params):
    with socket.create_connection(('127.0.0.1', args.port), timeout=15) as sock:
        sock.settimeout(120)
        sock.sendall((json.dumps({'id': 1, 'cmd': cmd, 'args': params})+'\n').encode())
        response = json.loads(sock.makefile('r').readline())
    if not response.get('ok'):
        raise RuntimeError(response)
    return response['result']

print(json.dumps(call('status')), flush=True)
call('pose', x=8, y=5.5, z=-9, pitch=-20, yaw=138)
call('look', x=0, y=1.5, z=0)
call('time', tod=0.0)
call('wait', frames=180)
call('run', src='main.set_process(false); return true')
try:
    result = call('run', src='''var result = {"lava_surfaces":0,"vertices":0,"lights":[]}
for node in main.find_children("*", "MeshInstance3D", true, false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if mat is ShaderMaterial and mat.shader.resource_path == "res://shaders/lava.gdshader":
			mat.set_shader_parameter("preview_time", 2.0)
			result.lava_surfaces += 1
			result.vertices += node.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX].size()
for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.get_parent() == client and lamp.visible:
		result.lights.append([lamp.position.x,lamp.position.y,lamp.position.z,lamp.light_energy])
return result''')
    (args.output/'state.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    call('shot', path=str((args.output/'raised-lit.png').resolve()), settle=False, warm=24)
    call('run', src='''for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.get_parent() != client:
		continue
	lamp.set_meta("lava_review_energy", lamp.light_energy)
	lamp.light_energy = 0.0
return true''')
    call('shot', path=str((args.output/'raised-unlit.png').resolve()), settle=False, warm=24)
    call('run', src='''for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.get_parent() == client:
		lamp.light_energy = lamp.get_meta("lava_review_energy", 0.0)
return true''')
    call('pose', x=5, y=2.0, z=-7, pitch=0, yaw=138)
    call('look', x=0, y=1.1, z=0)
    call('shot', path=str((args.output/'low-angle.png').resolve()), settle=False, warm=24)
finally:
    call('run', src='''for node in main.find_children("*", "MeshInstance3D", true, false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if mat is ShaderMaterial and mat.shader.resource_path == "res://shaders/lava.gdshader":
			mat.set_shader_parameter("preview_time", -1.0)
for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.has_meta("lava_review_energy"):
		lamp.light_energy = lamp.get_meta("lava_review_energy")
		lamp.remove_meta("lava_review_energy")
main.set_process(true)
return true''')
print(args.output, flush=True)
