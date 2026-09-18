#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Check native waterfall relief and lamp stability on disposable port 30881."""
import json
import socket
from pathlib import Path

out = Path('/tmp/goanna-lava-fall-review')
out.mkdir(parents=True, exist_ok=True)

def call(cmd, **args):
    with socket.create_connection(('127.0.0.1', 30881), timeout=15) as sock:
        sock.settimeout(120)
        sock.sendall((json.dumps({'id': 1, 'cmd': cmd, 'args': args})+'\n').encode())
        reply = json.loads(sock.makefile('r').readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']

call('run', src='main.headlight_auto=false; main.headlight.light_energy=0; client.set_show_body(false); client.set_light_flicker(false); return true')
call('time', tod=0.0)
call('run', src='ResourceLoader.load("res://shaders/lava.gdshader", "Shader", ResourceLoader.CACHE_MODE_REPLACE); return true')
states = []
try:
    for i, x in enumerate([6.0, 6.6, 5.4]):
        call('pose', x=x, y=3.0, z=-9.0, pitch=0, yaw=145)
        call('look', x=0, y=2.0, z=0)
        call('wait', frames=180)
        call('run', src='main.set_process(false); return true')
        state = call('run', src='''var result = {"lamps":[],"side_vertices":0,"raised_side_vertices":0,"seam_errors":0}
var shared = {}
for lamp in main.find_children("*", "OmniLight3D", true, false):
	if lamp.get_parent() == client and lamp.visible:
		result.lamps.append([lamp.position.x,lamp.position.y,lamp.position.z,lamp.light_energy,lamp.light_specular])
for node in main.find_children("*", "MeshInstance3D", true, false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if not mat is ShaderMaterial or mat.shader.resource_path != "res://shaders/lava.gdshader":
			continue
		mat.set_shader_parameter("preview_time",2.0)
		var arrays = node.mesh.surface_get_arrays(i)
		var positions = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var colours = arrays[Mesh.ARRAY_COLOR]
		var directions = arrays[Mesh.ARRAY_CUSTOM1]
		for v in positions.size():
			var direction = Vector3(directions[v*3],directions[v*3+1],directions[v*3+2])
			var displacement = direction * colours[v].a
			var key = Vector3i((positions[v]*1000).round())
			if shared.has(key) and shared[key].distance_to(displacement)>0.01:
				result.seam_errors += 1
			shared[key] = displacement
			if abs(normals[v].y) < 0.1:
				result.side_vertices += 1
				if colours[v].a > 0.9 and abs(direction.dot(normals[v]))>0.5:
					result.raised_side_vertices += 1
return result''')['value']
        states.append(state)
        call('shot', path=str(out/f'view-{i}.png'), settle=False, warm=24)
        call('run', src='main.set_process(true); return true')
finally:
    call('run', src='''for node in main.find_children("*", "MeshInstance3D", true, false):
	if not node.mesh:
		continue
	for i in node.mesh.get_surface_count():
		var mat = node.get_active_material(i)
		if mat is ShaderMaterial and mat.shader.resource_path == "res://shaders/lava.gdshader":
			mat.set_shader_parameter("preview_time",-1.0)
main.set_process(true)
return true''')
(out/'state.json').write_text(json.dumps(states, indent=2))
lamp_sets = [sorted(s['lamps']) for s in states]
assert lamp_sets[0] == lamp_sets[1] == lamp_sets[2], 'Camera sidestep changed active lava lamps'
assert all(s['raised_side_vertices'] > 100 for s in states), 'Falling sides lost relief'
assert all(s['seam_errors'] == 0 for s in states), 'Displacement differs across shared vertices'
assert all(lamp[4] == 0 for lamp in states[0]['lamps']), 'Lava has point-light specular hotspots'
print(json.dumps({'stable_lamps': len(lamp_sets[0]), 'raised_side_vertices': states[0]['raised_side_vertices'], 'seam_errors': states[0]['seam_errors']}))
